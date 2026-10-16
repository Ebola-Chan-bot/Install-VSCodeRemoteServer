using System;
using System.Diagnostics;
using System.IO;

public class SshWrapper
{
    public static void Main(string[] args)
    {
        string dir = @"C:\Users\vhtmf\ssh-wrap";
        string log = Path.Combine(dir, "calls.log");
        string dbg = Path.Combine(dir, "ssh-debug-" + DateTime.Now.ToString("HHmmss-fff") + ".log");
        try
        {
            File.AppendAllText(log, DateTime.Now.ToString("HH:mm:ss.fff") + " RAW: " + Environment.CommandLine + "\r\n");
        }
        catch { }
        ProcessStartInfo psi = new ProcessStartInfo();
        psi.FileName = @"C:\Windows\System32\OpenSSH\ssh.exe";
        string cl = Environment.CommandLine;
        int i = cl.IndexOf(".exe", StringComparison.OrdinalIgnoreCase);
        string rest = (i >= 0) ? cl.Substring(i + 4) : "";
        if (rest.StartsWith("\"")) rest = rest.Substring(1);
        psi.Arguments = "-vvv -E \"" + dbg + "\" " + rest;
        psi.UseShellExecute = false;
        try
        {
            Process p = Process.Start(psi);
            p.WaitForExit();
            try
            {
                File.AppendAllText(log, DateTime.Now.ToString("HH:mm:ss.fff") + " EXIT=" + p.ExitCode + " dbg=" + Path.GetFileName(dbg) + "\r\n");
            }
            catch { }
            Environment.Exit(p.ExitCode);
        }
        catch (Exception e)
        {
            try
            {
                File.AppendAllText(log, DateTime.Now.ToString("HH:mm:ss.fff") + " WRAPPER_ERR: " + e.Message + "\r\n");
            }
            catch { }
            Environment.Exit(255);
        }
    }
}
