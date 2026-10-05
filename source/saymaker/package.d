/**
 * Generate images and video on SayMaker (https://saymaker.ai) from D.
 *
 * ---
 * import saymaker;
 * auto r = generate("matte black ceramic mug on pale oak, soft window light");
 * if (r.ok) writeln(r.url); else writeln(r.reason, ": ", r.message);
 * auto v = generateVideo("a fox trotting through fresh snow", VideoOptions(6));
 * ---
 *
 * One API key runs the whole shelf on your own credits: Veo 3.1, Kling 3.0,
 * Seedance 2.0, MiniMax H3, Nano Banana 2, GPT Image 2.5, Seedream 5.0 and
 * more. Set `apiKey` or SAYMAKER_API_KEY; create a key at
 * https://saymaker.ai/settings/apikeys. Uses std.net.curl.
 */
module saymaker;

import core.thread : Thread;
import core.time : msecs, seconds;
import std.algorithm : canFind;
import std.datetime.systime : Clock;
import std.json;
import std.net.curl : HTTP, post;
import std.process : environment;
import std.string : strip, startsWith, toLower;

/// Why a call failed, in terms of what to do next.
enum Reason { none, auth, quota, plan, busy, rejected, timeout, other }

/// The outcome of a call: the file URL, or why there is none.
struct Result { bool ok; string url; Reason reason; string message; }

/// Settings for an image. `ImageOptions.init` is valid.
struct ImageOptions
{
    string model;        /// default saymaker-image-v1, or nano-banana-2-lite for an edit
    string imageUrl;     /// a public http(s) url; makes the call an edit
    string aspectRatio;  /// "1:1", "16:9", "9:16", "4:3", "3:4"
    string apiKey;       /// default SAYMAKER_API_KEY
    int pollMillis = 5000;
    int timeoutSeconds = 4500; /// covers the free-account queue
}

/// Settings for a clip. `VideoOptions.init` is valid.
struct VideoOptions
{
    int duration;                       /// seconds, where the model offers a choice
    string model = "minimax-h3-fast";   /// the one a free account can run
    string imageUrl;                    /// optional first frame
    string resolution;                  /// "480p", "720p", "1080p"
    string aspectRatio = "16:9";
    bool sound = true;
    string apiKey;
    int pollMillis = 10_000;
    int timeoutSeconds = 5400;
}

/// Service root, changeable for a test or a proxy.
__gshared string baseUrl = "https://saymaker.ai";

/// POST a JSON body and return the decoded envelope. Replaceable in tests.
__gshared JSONValue delegate(string url, string body, string key) transport;

/// Model id to the routing field the API expects next to it. Unlisted ids go as "kie".
immutable string[string] models;

shared static this()
{
    models = [
        "saymaker-image-v1": "kie", "nano-banana-2-lite": "kie", "nano-banana-2": "poyo",
        "nano-banana-pro": "poyo", "gpt-image-2": "poyo", "gpt-image-2-5-flare": "kie",
        "seedream-5-lite": "poyo", "seedream-5-pro": "kie", "qwen-image-3-pro": "kie",
        "grok-imagine-image-2-0": "poyo", "minimax-h3-fast": "vgenv", "minimax-h3": "poyo",
        "seedance-2": "kie", "seedance-2-fast": "kie", "seedance-2-5": "kie", "veo-3-1": "kie",
        "kling-3-0": "kie", "kling-3-0-turbo": "kie", "wan-3-0": "kie", "ltx-2-5-fast": "replicate",
    ];
    transport = (string url, string body, string key) {
        auto http = HTTP();
        http.addRequestHeader("Authorization", "Bearer " ~ key);
        http.addRequestHeader("Content-Type", "application/json");
        http.addRequestHeader("User-Agent", "saymaker-d/0.1.0");
        return parseJSON(cast(string) post!ubyte(url, body, http).idup);
    };
}

enum keysUrl = "https://saymaker.ai/settings/apikeys";

private Result fail(Reason r, string msg) { return Result(false, null, r, "saymaker: " ~ msg); }

/// Map a refusal message to the reason that says what to do next.
Reason classify(string message, bool busy = false)
{
    auto low = message.toLower;
    if (busy || low.canFind("is rendering") || low.canFind("at once")) return Reason.busy;
    if (low.canFind("api key") || low.canFind("no auth")) return Reason.auth;
    if (low.canFind("insufficient credits")) return Reason.quota;
    if (low.canFind("subscription") || low.canFind("plan") || low.canFind("sign in")) return Reason.plan;
    return Reason.other;
}

private bool has(const JSONValue v, string k)
{
    return v.type == JSONType.object && (k in v.object) !is null;
}

private Result run(string media, string scene, string model, string prompt, JSONValue options,
                   string apiKey, int pollMillis, int timeoutSeconds)
{
    if (prompt.strip.length == 0) return fail(Reason.other, "prompt is required");
    auto key = apiKey.length ? apiKey : environment.get("SAYMAKER_API_KEY", "");
    if (key.length == 0) return fail(Reason.auth, "an API key is required; create one at " ~ keysUrl);

    JSONValue body = [
        "provider": JSONValue(model in models ? models[model] : "kie"),
        "mediaType": JSONValue(media), "model": JSONValue(model), "scene": JSONValue(scene),
        "prompt": JSONValue(prompt), "options": options,
    ];
    JSONValue env;
    try env = transport(baseUrl ~ "/api/ai/generate", body.toString, key);
    catch (Exception e) return fail(Reason.other, e.msg);
    auto data = has(env, "data") ? env["data"] : JSONValue.emptyObject;
    // Refusals answer HTTP 200 with code -1; the status code alone reads as success.
    if (!has(env, "code") || env["code"].integer != 0)
    {
        auto msg = has(env, "message") && env["message"].type == JSONType.string ? env["message"].str : "request refused";
        return Result(false, null, classify(msg, has(data, "busy")), "saymaker: " ~ msg);
    }
    // A signed-out request is also a 200 with code 0; only `wall` tells it apart.
    if (has(data, "wall") && data["wall"].type == JSONType.true_)
        return fail(Reason.auth, "an API key is required; create one at " ~ keysUrl);
    if (!has(data, "id")) return fail(Reason.other, "the service returned no task id");
    JSONValue poll = ["taskId": data["id"]];

    // Free-account runs only reach the model on the poll that crosses the end of
    // the queue wait, so polling is what starts the work.
    auto deadline = Clock.currTime + timeoutSeconds.seconds;
    while (Clock.currTime < deadline)
    {
        Thread.sleep(pollMillis.msecs);
        JSONValue q;
        try q = transport(baseUrl ~ "/api/ai/query", poll.toString, key);
        catch (Exception) continue; // a dropped poll is not a failed generation
        if (!has(q, "code") || q["code"].integer != 0 || !has(q, "data")) continue;
        auto d = q["data"];
        foreach (field; ["cleanImages", "images", "videos"])
            if (has(d, field) && d[field].type == JSONType.array && d[field].array.length)
                return Result(true, d[field].array[0].str);
        auto status = has(d, "status") && d["status"].type == JSONType.string ? d["status"].str.toLower : "";
        if (status == "failed" || status == "error")
            return fail(Reason.rejected, "the run failed; reword the prompt rather than retrying");
    }
    return fail(Reason.timeout, "deadline passed; the run may still finish in your SayMaker history");
}

private bool badUrl(string u) { return u.length && !(u.startsWith("http://") || u.startsWith("https://")); }

/// Generate one image, or edit `o.imageUrl`, and return its URL.
Result generate(string prompt, ImageOptions o = ImageOptions.init)
{
    if (badUrl(o.imageUrl)) return fail(Reason.other, "imageUrl must be a public http(s) url");
    bool edit = o.imageUrl.length > 0;
    JSONValue opts = [
        "size": JSONValue(o.aspectRatio.length ? o.aspectRatio : (edit ? "auto" : "1:1")),
        "resolution": JSONValue("1K"), "n": JSONValue(1),
    ];
    if (edit) opts["image_input"] = JSONValue([o.imageUrl]);
    auto model = o.model.length ? o.model : (edit ? "nano-banana-2-lite" : "saymaker-image-v1");
    return run("image", edit ? "image-to-image" : "text-to-image", model, prompt, opts, o.apiKey, o.pollMillis, o.timeoutSeconds);
}

/// Generate one clip, or animate `o.imageUrl` as the first frame, and return its URL.
Result generateVideo(string prompt, VideoOptions o = VideoOptions.init)
{
    if (badUrl(o.imageUrl)) return fail(Reason.other, "imageUrl must be a public http(s) url");
    JSONValue opts = ["aspect_ratio": JSONValue(o.aspectRatio), "sound": JSONValue(o.sound)];
    if (o.imageUrl.length) opts["image_input"] = JSONValue([o.imageUrl]);
    if (o.duration) opts["duration"] = JSONValue(o.duration);
    if (o.resolution.length) opts["resolution"] = JSONValue(o.resolution);
    return run("video", o.imageUrl.length ? "image-to-video" : "text-to-video", o.model, prompt, opts, o.apiKey, o.pollMillis, o.timeoutSeconds);
}

unittest
{
    JSONValue[] bodies;
    string finalJson;
    auto saved = transport;
    scope (exit) transport = saved;
    transport = (string url, string body, string key) {
        bodies ~= parseJSON(body);
        return parseJSON(url.canFind("/api/ai/generate") ? `{"code":0,"data":{"id":"row1"}}` : `{"code":0,"data":` ~ finalJson ~ `}`);
    };
    finalJson = `{"images":["m"],"cleanImages":["c"]}`;
    ImageOptions io = { apiKey: "sk", pollMillis: 0 };
    auto r = generate("x", io);
    assert(r.ok && r.url == "c");
    assert(bodies[0]["model"].str == "saymaker-image-v1" && bodies[1]["taskId"].str == "row1");
    bodies = null;
    finalJson = `{"videos":["v"]}`;
    VideoOptions vo = { duration: 6, apiKey: "sk", pollMillis: 0 };
    auto v = generateVideo("x", vo);
    assert(v.ok && v.url == "v");
    assert(bodies[0]["provider"].str == "vgenv" && bodies[0]["options"]["duration"].integer == 6);
    assert(classify("insufficient credits") == Reason.quota);
    assert(classify("Your current run is rendering. Plans on the pricing page") == Reason.busy);
}
