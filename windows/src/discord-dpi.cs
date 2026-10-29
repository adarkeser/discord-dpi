// Helper for discord-dpi on Windows. build.ps1 compiles it with the C# compiler
// that ships with Windows (.NET Framework 4, C# 5), so it uses nothing newer.
//
// It runs as a Windows service next to ciadpi and does two jobs:
//   DNS    An NRPT rule sends lookups for the Discord domains here. Each name
//          is answered with its own loopback address (127.21.x.y, from a hash
//          of the name) instead of the real one.
//   Relay  Listens on those addresses on port 443, reads the site name from
//          the TLS handshake, looks up the real address on an unfiltered DNS
//          server and passes the connection through ciadpi.
// So every program that talks to Discord goes through the bypass, Discord's
// updater included, and no proxy setting is needed. (Discord on Windows does
// not reliably follow the system proxy.)
//
// Why one address per name: Chromium reuses an open connection for another
// host when both resolve to the same address and the certificate covers both.
// With one shared address it could send a request to the wrong server.
//
//   discord-dpi.exe                                    run as the service
//   discord-dpi.exe run                                the same in a console, for debugging
//   discord-dpi.exe resolve <name> <port> <server>...  print the real IPv4 address

using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.ServiceProcess;
using System.Text;
using System.Threading;

static class Program
{
    // Windows reports an ICMP "port unreachable" for an earlier UDP reply as an
    // error on the next receive. This ioctl turns that off.
    const int SioUdpConnReset = -1744830452;

    static Settings config;
    static Socket dnsSocket;
    static volatile bool running;

    public static Settings Config { get { return config; } }
    public static bool Running { get { return running; } }

    static int Main(string[] args)
    {
        if (args.Length == 0)
        {
            if (Environment.UserInteractive)
            {
                Console.Error.WriteLine("This is the discord-dpi service. Set it up with install.cmd.");
                return 2;
            }
            ServiceBase.Run(new HelperService());
            return 0;
        }
        if (args[0] == "run")
        {
            Start();
            Console.WriteLine("Running. Press Enter to stop.");
            Console.ReadLine();
            Stop();
            return 0;
        }
        if (args[0] == "resolve" && args.Length >= 4)
        {
            int port = int.Parse(args[2]);
            var servers = new List<IPEndPoint>();
            for (int i = 3; i < args.Length; i++)
                servers.Add(new IPEndPoint(IPAddress.Parse(args[i]), port));
            IPAddress ip = Upstream.Resolve(args[1].ToLowerInvariant(), servers);
            if (ip == null) return 1;
            Console.WriteLine(ip);
            return 0;
        }
        Console.Error.WriteLine("usage: discord-dpi.exe [run | resolve <name> <port> <server>...]");
        return 2;
    }

    public static void Start()
    {
        config = Settings.Load(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "settings.ini"));
        Log.Open(config.LogFile);
        running = true;
        dnsSocket = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
        dnsSocket.IOControl(SioUdpConnReset, new byte[] { 0, 0, 0, 0 }, null);
        try
        {
            dnsSocket.Bind(new IPEndPoint(config.DnsListen, 53));
        }
        catch (SocketException e)
        {
            Log.Write("Cannot listen for DNS on " + config.DnsListen + ":53: " + e.Message);
            throw;
        }
        Spawn(DnsLoop);
        Log.Write("Started");
    }

    public static void Stop()
    {
        running = false;
        if (dnsSocket != null) dnsSocket.Close();
        Relay.StopAll();
        Log.Write("Stopped");
    }

    public static Thread Spawn(ThreadStart fn)
    {
        var t = new Thread(fn, 256 * 1024);
        t.IsBackground = true;
        t.Start();
        return t;
    }

    static void DnsLoop()
    {
        byte[] buf = new byte[1500];
        while (running)
        {
            EndPoint from = new IPEndPoint(IPAddress.Any, 0);
            int n;
            try { n = dnsSocket.ReceiveFrom(buf, ref from); }
            catch (SocketException) { continue; }
            catch (ObjectDisposedException) { return; }

            byte[] reply;
            try { reply = LocalDns.Answer(buf, n, config); }
            catch (Exception) { reply = null; }   // malformed query
            if (reply == null) continue;

            try { dnsSocket.SendTo(reply, from); }
            catch (SocketException) { }
            catch (ObjectDisposedException) { return; }
        }
    }
}

class HelperService : ServiceBase
{
    public HelperService()
    {
        ServiceName = "discord-dpi";
        CanStop = true;
        CanShutdown = true;
        // AutoLog writes to the event log under a source nobody registered,
        // which LOCAL SERVICE is not allowed to create.
        AutoLog = false;
    }

    protected override void OnStart(string[] args) { Program.Start(); }
    protected override void OnStop() { Program.Stop(); }
    protected override void OnShutdown() { Program.Stop(); }
}

// settings.ini, written by install.ps1. One key=value per line.
class Settings
{
    public int SocksPort = 10800;
    public IPAddress DnsListen = IPAddress.Loopback;
    public byte RelayNet = 21;   // relay addresses are 127.<RelayNet>.x.y
    public List<IPEndPoint> Upstreams = new List<IPEndPoint>();
    public List<string> Domains = new List<string>();
    public string LogFile;

    public static Settings Load(string path)
    {
        var s = new Settings();
        string servers = "", port = "53";
        foreach (string raw in File.ReadAllLines(path))
        {
            string line = raw.Trim();
            int eq = line.IndexOf('=');
            if (line.StartsWith("#", StringComparison.Ordinal) || eq < 0) continue;
            string key = line.Substring(0, eq).Trim();
            string val = line.Substring(eq + 1).Trim();
            switch (key)
            {
                case "socks_port": s.SocksPort = int.Parse(val); break;
                case "dns_listen": s.DnsListen = IPAddress.Parse(val); break;
                case "relay_prefix": s.RelayNet = ParsePrefix(val); break;
                case "dns_servers": servers = val; break;
                case "dns_port": port = val; break;
                case "log_file": s.LogFile = val; break;
                case "domains":
                    foreach (string d in Items(val)) s.Domains.Add(d.ToLowerInvariant());
                    break;
            }
        }
        foreach (string a in Items(servers))
            s.Upstreams.Add(new IPEndPoint(IPAddress.Parse(a), int.Parse(port)));
        if (s.Upstreams.Count == 0 || s.Domains.Count == 0)
            throw new InvalidDataException("settings.ini needs dns_servers and domains");
        return s;
    }

    static string[] Items(string v)
    {
        return v.Split(new[] { ',', ' ' }, StringSplitOptions.RemoveEmptyEntries);
    }

    // "127.21" -> 21
    static byte ParsePrefix(string v)
    {
        string[] parts = v.Split('.');
        if (parts.Length != 2 || parts[0] != "127")
            throw new InvalidDataException("relay_prefix must look like 127.21");
        return byte.Parse(parts[1]);
    }

    public bool IsDiscord(string name)
    {
        foreach (string d in Domains)
            if (name == d || name.EndsWith("." + d, StringComparison.Ordinal)) return true;
        return false;
    }

    // The loopback address handed out for a name: 127.<RelayNet>.x.y, with x.y
    // from an FNV-1a hash. Two names can land on the same one; that only brings
    // back the rare connection reuse, since the relay routes by the site name.
    public IPAddress AddressFor(string name)
    {
        uint h = 2166136261u;
        foreach (char c in name)
        {
            h ^= c;
            h *= 16777619u;
        }
        int n = (int)(h % 65534) + 1;
        return new IPAddress(new byte[] { 127, RelayNet, (byte)(n >> 8), (byte)n });
    }
}

// The DNS server the NRPT rule points at. It never asks anyone else: Discord
// names get a relay address, anything else is refused.
static class LocalDns
{
    const int Ttl = 30;

    // The reply to one query, or null to ignore it.
    public static byte[] Answer(byte[] q, int n, Settings s)
    {
        if (n < 17 || (q[2] & 0x80) != 0) return null;   // too short, or not a query

        var name = new StringBuilder();
        int pos = 12;
        while (q[pos] != 0)
        {
            int len = q[pos];
            if (len > 63 || pos + 1 + len >= n) return null;
            if (name.Length > 0) name.Append('.');
            name.Append(Encoding.ASCII.GetString(q, pos + 1, len));
            pos += 1 + len;
        }
        pos++;   // the root label
        if (pos + 4 > n) return null;
        int qtype = (q[pos] << 8) | q[pos + 1];
        int qclass = (q[pos + 2] << 8) | q[pos + 3];
        int end = pos + 4;
        string host = name.ToString().ToLowerInvariant();

        int opcode = (q[2] >> 3) & 0x0F;
        int questions = (q[4] << 8) | q[5];
        int rcode = 0;
        IPAddress addr = null;
        if (opcode != 0 || questions != 1) rcode = 4;   // not implemented
        else if (!s.IsDiscord(host)) rcode = 5;         // refused
        else if (qtype == 1 && qclass == 1)
        {
            addr = s.AddressFor(host);
            if (!Relay.Listen(addr))
            {
                addr = null;
                rcode = 2;   // server failure
            }
        }
        // Any other record type (AAAA, HTTPS, ...) gets an empty answer, so
        // programs use the IPv4 address above.

        var r = new MemoryStream();
        r.WriteByte(q[0]);
        r.WriteByte(q[1]);
        r.WriteByte((byte)(0x84 | (q[2] & 0x79)));   // response, authoritative, same opcode and RD
        r.WriteByte((byte)(0x80 | rcode));           // recursion available
        r.Write(new byte[] { 0, 1, 0, (byte)(addr != null ? 1 : 0), 0, 0, 0, 0 }, 0, 8);
        r.Write(q, 12, end - 12);                    // the question, copied
        if (addr != null)
        {
            // Name pointer to the question, type A, class IN, TTL, 4 bytes of address.
            r.Write(new byte[] { 0xC0, 12, 0, 1, 0, 1, 0, 0, 0, Ttl, 0, 4 }, 0, 12);
            r.Write(addr.GetAddressBytes(), 0, 4);
        }
        return r.ToArray();
    }
}

// Asks the unfiltered DNS servers (OpenDNS on port 443) for real addresses.
static class Upstream
{
    class Entry
    {
        public IPAddress Address;
        public DateTime Expires;
    }

    static readonly Dictionary<string, Entry> cache = new Dictionary<string, Entry>();
    static readonly Random random = new Random();

    // The real IPv4 address of name, or null.
    public static IPAddress Resolve(string name, List<IPEndPoint> servers)
    {
        Entry e;
        lock (cache)
        {
            if (cache.TryGetValue(name, out e) && e.Expires > DateTime.UtcNow) return e.Address;
        }
        foreach (IPEndPoint server in servers)
        {
            try
            {
                int ttl;
                IPAddress ip = Query(name, server, out ttl);
                if (ip == null) continue;
                lock (cache)
                {
                    cache[name] = new Entry
                    {
                        Address = ip,
                        Expires = DateTime.UtcNow.AddSeconds(Math.Max(60, Math.Min(ttl, 600)))
                    };
                }
                return ip;
            }
            catch (Exception) { }   // timeout, unreachable or a bad answer: try the next server
        }
        return null;
    }

    static IPAddress Query(string name, IPEndPoint server, out int ttl)
    {
        ttl = 0;
        byte[] q = BuildQuery(name);
        using (var udp = new UdpClient(AddressFamily.InterNetwork))
        {
            udp.Client.ReceiveTimeout = 2000;
            udp.Connect(server);
            udp.Send(q, q.Length);
            while (true)
            {
                IPEndPoint from = null;
                byte[] m = udp.Receive(ref from);   // throws when the timeout runs out
                if (m.Length >= 12 && m[0] == q[0] && m[1] == q[1]) return ParseA(m, out ttl);
            }
        }
    }

    static byte[] BuildQuery(string name)
    {
        int id;
        lock (random) id = random.Next(65536);
        var q = new MemoryStream();
        q.WriteByte((byte)(id >> 8));
        q.WriteByte((byte)id);
        q.Write(new byte[] { 1, 0, 0, 1, 0, 0, 0, 0, 0, 0 }, 0, 10);   // recursion desired, one question
        foreach (string label in name.Split('.'))
        {
            if (label.Length == 0 || label.Length > 63) throw new ArgumentException("bad name: " + name);
            byte[] b = Encoding.ASCII.GetBytes(label);
            q.WriteByte((byte)b.Length);
            q.Write(b, 0, b.Length);
        }
        q.Write(new byte[] { 0, 0, 1, 0, 1 }, 0, 5);   // root label, type A, class IN
        return q.ToArray();
    }

    // The first A record in an answer, or null.
    static IPAddress ParseA(byte[] m, out int ttl)
    {
        ttl = 0;
        if ((m[3] & 0x0F) != 0) return null;   // error answer
        int p = SkipName(m, 12) + 4;           // the question
        int count = (m[6] << 8) | m[7];
        for (int i = 0; i < count; i++)
        {
            p = SkipName(m, p);
            int type = (m[p] << 8) | m[p + 1];
            int len = (m[p + 8] << 8) | m[p + 9];
            if (type == 1 && len == 4)
            {
                ttl = (m[p + 4] << 24) | (m[p + 5] << 16) | (m[p + 6] << 8) | m[p + 7];
                var ip = new IPAddress(new byte[] { m[p + 10], m[p + 11], m[p + 12], m[p + 13] });
                // A loopback answer would send the relay back to itself.
                return IPAddress.IsLoopback(ip) || ip.Equals(IPAddress.Any) ? null : ip;
            }
            p += 10 + len;   // CNAME and the like
        }
        return null;
    }

    static int SkipName(byte[] m, int p)
    {
        while (true)
        {
            int len = m[p];
            if (len == 0) return p + 1;
            if ((len & 0xC0) == 0xC0) return p + 2;   // compression pointer
            p += 1 + len;
        }
    }
}

// Accepts connections on the relay addresses and passes them through ciadpi.
static class Relay
{
    static readonly Dictionary<string, TcpListener> listeners = new Dictionary<string, TcpListener>();

    // Makes sure something listens on addr:443. False if it can't.
    public static bool Listen(IPAddress addr)
    {
        string key = addr.ToString();
        lock (listeners)
        {
            TcpListener l;
            if (listeners.TryGetValue(key, out l)) return l != null;
            l = null;
            try
            {
                l = new TcpListener(addr, 443);
                l.Start(64);
                l.BeginAcceptSocket(OnAccept, l);
            }
            catch (SocketException e)
            {
                Log.Write("Cannot listen on " + key + ":443: " + e.Message);
                if (l != null) l.Stop();
                l = null;
            }
            listeners[key] = l;
            return l != null;
        }
    }

    public static void StopAll()
    {
        lock (listeners)
        {
            foreach (TcpListener l in listeners.Values)
                if (l != null) l.Stop();
            listeners.Clear();
        }
    }

    static void OnAccept(IAsyncResult ar)
    {
        var l = (TcpListener)ar.AsyncState;
        Socket client = null;
        try { client = l.EndAcceptSocket(ar); }
        catch (ObjectDisposedException) { return; }   // stopped
        catch (SocketException) { }                   // the client gave up first
        try { l.BeginAcceptSocket(OnAccept, l); }
        catch (Exception) { }                         // stopped
        if (client != null) Program.Spawn(delegate { Handle(client); });
    }

    static void Handle(Socket client)
    {
        Socket server = null;
        try
        {
            client.NoDelay = true;
            client.ReceiveTimeout = 10000;
            byte[] hello = Tls.ReadRecord(client);
            string host = hello == null ? null : Tls.ServerName(hello);
            if (host == null || !Program.Config.IsDiscord(host)) return;

            IPAddress ip = Upstream.Resolve(host, Program.Config.Upstreams);
            if (ip == null)
            {
                Log.Write("Could not look up " + host + " on the unfiltered DNS servers");
                return;
            }
            try
            {
                server = Socks.Connect(Program.Config.SocksPort, ip, 443);
            }
            catch (Exception e)
            {
                if (Program.Running) Log.Write(host + " (" + ip + "): " + e.Message);
                return;
            }
            server.Send(hello);
            client.ReceiveTimeout = 0;
            Pipe(client, server);
        }
        catch (Exception) { }   // resets and timeouts are normal here
        finally
        {
            client.Close();
            if (server != null) server.Close();
        }
    }

    static void Pipe(Socket client, Socket server)
    {
        Thread back = Program.Spawn(delegate { Pump(server, client); });
        Pump(client, server);
        back.Join();
    }

    // Copies one direction until it ends. A clean end is passed on as a half
    // close. An error closes both sockets, which also ends the other direction.
    static void Pump(Socket from, Socket to)
    {
        byte[] buf = new byte[16384];
        try
        {
            int n;
            while ((n = from.Receive(buf)) > 0) to.Send(buf, n, SocketFlags.None);
            to.Shutdown(SocketShutdown.Send);
        }
        catch (Exception)
        {
            from.Close();
            to.Close();
        }
    }
}

static class Tls
{
    // The first TLS record of a connection (it holds the ClientHello), or null
    // if the connection doesn't start with a handshake.
    public static byte[] ReadRecord(Socket s)
    {
        byte[] head = new byte[5];
        if (!Io.ReadFull(s, head, 0, 5) || head[0] != 0x16) return null;
        int len = (head[3] << 8) | head[4];
        if (len == 0 || len > 16384) return null;
        byte[] rec = new byte[5 + len];
        Buffer.BlockCopy(head, 0, rec, 0, 5);
        return Io.ReadFull(s, rec, 5, len) ? rec : null;
    }

    // The server_name in a ClientHello record, or null.
    public static string ServerName(byte[] r)
    {
        try
        {
            if (r[5] != 1) return null;               // not a ClientHello
            int p = 5 + 4 + 2 + 32;                   // record header, handshake header, version, random
            p += 1 + r[p];                            // session id
            p += 2 + ((r[p] << 8) | r[p + 1]);        // cipher suites
            p += 1 + r[p];                            // compression methods
            int end = p + 2 + ((r[p] << 8) | r[p + 1]);
            p += 2;
            while (p + 4 <= end)
            {
                int type = (r[p] << 8) | r[p + 1];
                int len = (r[p + 2] << 8) | r[p + 3];
                p += 4;
                if (type == 0)
                {
                    // server_name: list length (2), name type (1, 0 = host name), name length (2), name
                    if (r[p + 2] != 0) return null;
                    int nlen = (r[p + 3] << 8) | r[p + 4];
                    return Encoding.ASCII.GetString(r, p + 5, nlen).ToLowerInvariant();
                }
                p += len;
            }
        }
        catch (IndexOutOfRangeException) { }
        catch (ArgumentException) { }
        return null;
    }
}

static class Socks
{
    // A connection to ip:port through ciadpi (SOCKS5, no auth). The address is
    // sent as an IP: a name would make ciadpi look it up, and the NRPT rule
    // would point it back here.
    public static Socket Connect(int socksPort, IPAddress ip, int port)
    {
        var s = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
        try
        {
            s.NoDelay = true;
            s.ReceiveTimeout = 15000;
            s.Connect(IPAddress.Loopback, socksPort);
            s.Send(new byte[] { 5, 1, 0 });
            byte[] r = new byte[22];
            if (!Io.ReadFull(s, r, 0, 2) || r[0] != 5 || r[1] != 0)
                throw new IOException("ciadpi refused the SOCKS handshake");
            byte[] a = ip.GetAddressBytes();
            s.Send(new byte[] { 5, 1, 0, 1, a[0], a[1], a[2], a[3], (byte)(port >> 8), (byte)port });
            if (!Io.ReadFull(s, r, 0, 4)) throw new IOException("ciadpi closed the connection");
            if (r[1] != 0) throw new IOException("ciadpi could not connect (SOCKS error " + r[1] + ")");
            int rest = r[3] == 1 ? 6 : r[3] == 4 ? 18 : -1;   // bound address and port
            if (rest < 0 || !Io.ReadFull(s, r, 4, rest)) throw new IOException("bad SOCKS reply from ciadpi");
            s.ReceiveTimeout = 0;
            return s;
        }
        catch
        {
            s.Close();
            throw;
        }
    }
}

static class Io
{
    public static bool ReadFull(Socket s, byte[] buf, int off, int count)
    {
        while (count > 0)
        {
            int n = s.Receive(buf, off, count, SocketFlags.None);
            if (n <= 0) return false;
            off += n;
            count -= n;
        }
        return true;
    }
}

static class Log
{
    static string path;
    static readonly object gate = new object();

    public static void Open(string file) { path = file; }

    public static void Write(string msg)
    {
        string line = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + msg;
        if (Environment.UserInteractive) Console.WriteLine(line);
        if (string.IsNullOrEmpty(path)) return;
        lock (gate)
        {
            try
            {
                // Keep it small: start over once it passes 1 MB.
                var info = new FileInfo(path);
                if (info.Exists && info.Length > 1024 * 1024) info.Delete();
                File.AppendAllText(path, line + Environment.NewLine);
            }
            catch (Exception) { }   // logging must never take the service down
        }
    }
}
