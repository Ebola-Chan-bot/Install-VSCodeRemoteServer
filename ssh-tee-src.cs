using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;

public class SshTee
{
    static object _lk = new object();
    static string _dir = @"C:\Users\vhtmf\ssh-wrap";

    static void Log(string tag, byte[] buf, int n)
    {
        try
        {
            lock (_lk)
            {
                using (FileStream fs = new FileStream(Path.Combine(_dir, "tee.log"), FileMode.Append, FileAccess.Write))
                {
                    string head = DateTime.Now.ToString("HH:mm:ss.fff") + " [" + tag + "] " + n + "B: ";
                    fs.Write(Encoding.UTF8.GetBytes(head), 0, Encoding.UTF8.GetByteCount(head));
                    fs.Write(buf, 0, Math.Min(n, 256));
                    fs.Write(Encoding.UTF8.GetBytes("\r\n"), 0, 2);
                }
            }
        }
        catch { }
    }

    static void Pump(Stream src, Stream dst, string tag)
    {
        byte[] buf = new byte[8192];
        try
        {
            while (true)
            {
                int n = src.Read(buf, 0, buf.Length);
                if (n <= 0) { Log(tag + "-EOF", buf, 0); break; }
                Log(tag, buf, n);
                dst.Write(buf, 0, n);
                dst.Flush();
            }
        }
        catch (Exception e) { Log(tag + "-ERR", Encoding.UTF8.GetBytes(e.Message), Encoding.UTF8.GetByteCount(e.Message)); }
    }

    public static void Main(string[] args)
    {
        string dbg = Path.Combine(_dir, "ssh-debug-" + DateTime.Now.ToString("HHmmss-fff") + ".log");
        string cl = Environment.CommandLine;
        int i = cl.IndexOf(".exe", StringComparison.OrdinalIgnoreCase);
        string rest = (i >= 0) ? cl.Substring(i + 4) : "";
        if (rest.StartsWith("\"")) rest = rest.Substring(1);
        Log("SPAWN", Encoding.UTF8.GetBytes(rest), Encoding.UTF8.GetByteCount(rest));

        ProcessStartInfo psi = new ProcessStartInfo();
        psi.FileName = @"C:\Windows\System32\OpenSSH\ssh.exe";
        psi.Arguments = "-vvv -E \"" + dbg + "\" " + rest;
        psi.UseShellExecute = false;
        psi.RedirectStandardInput = true;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        Process p = Process.Start(psi);

        Thread tIn = new Thread(() => Pump(Console.OpenStandardInput(), p.StandardInput.BaseStream, "IN"));
        Thread tOut = new Thread(() => Pump(p.StandardOutput.BaseStream, Console.OpenStandardOutput(), "OUT"));
        Thread tErr = new Thread(() => Pump(p.StandardError.BaseStream, Console.OpenStandardError(), "ERR"));
        tIn.IsBackground = true; tOut.IsBackground = true; tErr.IsBackground = true;
        tIn.Start(); tOut.Start(); tErr.Start();
        p.WaitForExit();
        Log("EXIT", Encoding.UTF8.GetBytes(p.ExitCode.ToString()), 1);
        Environment.Exit(p.ExitCode);
    }
}
