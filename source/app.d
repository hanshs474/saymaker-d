/// saymaker "a prompt"           -> image URL
/// saymaker --video "a prompt"   -> clip URL   (set SAYMAKER_API_KEY)
import std.stdio;
import saymaker;

int main(string[] args)
{
    bool video = args.length > 1 && args[1] == "--video";
    auto rest = video ? args[2 .. $] : args[1 .. $];
    if (rest.length == 0) { stderr.writeln(`usage: saymaker [--video] "prompt"`); return 2; }
    auto r = video ? generateVideo(rest[0]) : generate(rest[0]);
    if (!r.ok) { stderr.writeln(r.reason, ": ", r.message); return 1; }
    writeln(r.url);
    return 0;
}
