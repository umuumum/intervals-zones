import Toybox.Application;
import Toybox.Communications;
import Toybox.Lang;
import Toybox.StringUtil;
import Toybox.System;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.WatchUi;

//! Holds the settings, the last known zone distribution, and the one web
//! request that fills it. Everything the views draw comes from here.
class Model {

    // ---- state the views read -------------------------------------------
    public var powerPct as Array<Float> = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0];
    public var hrPct as Array<Float> = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0];
    public var powerHours as Float = 0.0;
    public var hrHours as Float = 0.0;
    public var dataDate as String = "";      // wellness record the numbers came from
    public var hasData as Boolean = false;
    public var loading as Boolean = false;
    public var error as String or Null = null;

    // ---- settings --------------------------------------------------------
    private var _athleteId as String = "";
    private var _apiKey as String = "";
    private var _refreshMins as Number = 120;
    private var _lastFetch as Number = 0;    // epoch seconds

    private const POWER_ZONES = 7;
    private const HR_ZONES = 7;
    // Bumped so a cache written by the 5-zone build is discarded rather than
    // read back into a 7-slot array.
    private const CACHE_KEY = "zones_cache_v2";

    function initialize() {
        loadSettings();
        restore();
    }

    // ----------------------------------------------------------------------
    // settings & cache
    // ----------------------------------------------------------------------

    function loadSettings() as Void {
        _athleteId = str(Application.Properties.getValue("athleteId"), "");
        _apiKey = str(Application.Properties.getValue("apiKey"), "");
        var r = Application.Properties.getValue("refreshMins");
        _refreshMins = (r instanceof Lang.Number && r > 0) ? r : 120;
    }

    function isConfigured() as Boolean {
        return _athleteId.length() > 0 && _apiKey.length() > 0;
    }

    private function restore() as Void {
        var c = Application.Storage.getValue(CACHE_KEY);
        if (!(c instanceof Lang.Dictionary)) { return; }
        var p = c["p"];
        var h = c["h"];
        if (p instanceof Lang.Array && h instanceof Lang.Array) {
            powerPct = p as Array<Float>;
            hrPct = h as Array<Float>;
            powerHours = flt(c["ph"], 0.0);
            hrHours = flt(c["hh"], 0.0);
            dataDate = str(c["d"], "");
            _lastFetch = (c["t"] instanceof Lang.Number) ? c["t"] as Number : 0;
            hasData = true;
        }
    }

    private function persist() as Void {
        Application.Storage.setValue(CACHE_KEY, {
            "p" => powerPct,
            "h" => hrPct,
            "ph" => powerHours,
            "hh" => hrHours,
            "d" => dataDate,
            "t" => _lastFetch
        });
    }

    //! Minutes since the numbers were last refreshed, or -1 if never.
    function ageMinutes() as Number {
        if (_lastFetch == 0) { return -1; }
        var delta = Time.now().value() - _lastFetch;
        return (delta / 60).toNumber();
    }

    // ----------------------------------------------------------------------
    // fetching
    // ----------------------------------------------------------------------

    //! Fetch unless the cache is still fresh. `force` skips the freshness check.
    function refresh(force as Boolean) as Void {
        if (loading) { return; }
        if (!isConfigured()) {
            error = "Set athlete ID\nand API key";
            WatchUi.requestUpdate();
            return;
        }
        if (!force && _lastFetch != 0) {
            if (Time.now().value() - _lastFetch < _refreshMins * 60) { return; }
        }

        loading = true;
        error = null;
        WatchUi.requestUpdate();

        var now = Time.now();
        var newest = isoDate(now);
        var oldest = isoDate(now.subtract(new Time.Duration(4 * Gregorian.SECONDS_PER_DAY)));

        // Only the fields we draw. Keeps the response to a few hundred bytes
        // instead of the full wellness record for every day.
        var cols = "id,PwrZ1,PwrZ2,PwrZ3,PwrZ4,PwrZ5,PwrZ6,PwrZ7,"
                 + "HrZ1,HrZ2,HrZ3,HrZ4,HrZ5,HrZ6,HrZ7,PwrHrs,HrHrs";

        var url = "https://intervals.icu/api/v1/athlete/" + _athleteId + "/wellness";
        var params = {
            "oldest" => oldest,
            "newest" => newest,
            "fields" => cols
        };
        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :headers => {
                "Authorization" => "Basic " + basicAuth(),
                "Accept" => "application/json"
            },
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        };

        Communications.makeWebRequest(url, params, options, method(:onResponse));
    }

    private function basicAuth() as String {
        var raw = "API_KEY:" + _apiKey;
        return StringUtil.convertEncodedString(raw, {
            :fromRepresentation => StringUtil.REPRESENTATION_STRING_PLAIN_TEXT,
            :toRepresentation => StringUtil.REPRESENTATION_STRING_BASE64,
            :encoding => StringUtil.CHAR_ENCODING_UTF8
        }) as String;
    }

    function onResponse(code as Number, data) as Void {
        loading = false;

        if (code != 200) {
            error = (code == 401 || code == 403) ? "Auth failed\ncheck API key"
                  : (code < 0) ? "No connection" : "HTTP " + code;
            WatchUi.requestUpdate();
            return;
        }

        // The wellness list endpoint returns oldest-first. Walk it and keep the
        // newest record that actually carries the fields -- the bridge may not
        // have written today's yet.
        var record = null;
        if (data instanceof Lang.Array) {
            for (var i = 0; i < data.size(); i++) {
                var rec = data[i];
                if (rec instanceof Lang.Dictionary && carriesZones(rec)) { record = rec; }
            }
        } else if (data instanceof Lang.Dictionary && carriesZones(data)) {
            record = data;
        }

        if (record == null) {
            error = "No zone fields\nin wellness";
            WatchUi.requestUpdate();
            return;
        }

        var p = new [POWER_ZONES];
        for (var i = 0; i < POWER_ZONES; i++) {
            p[i] = flt(record["PwrZ" + (i + 1)], 0.0);
        }
        var h = new [HR_ZONES];
        for (var i = 0; i < HR_ZONES; i++) {
            h[i] = flt(record["HrZ" + (i + 1)], 0.0);
        }

        powerPct = p as Array<Float>;
        hrPct = h as Array<Float>;
        powerHours = flt(record["PwrHrs"], 0.0);
        hrHours = flt(record["HrHrs"], 0.0);
        dataDate = str(record["id"], "");
        hasData = true;
        error = null;
        _lastFetch = Time.now().value();
        persist();

        WatchUi.requestUpdate();
    }

    private function carriesZones(rec as Dictionary) as Boolean {
        for (var i = 1; i <= POWER_ZONES; i++) {
            if (rec["PwrZ" + i] != null) { return true; }
        }
        for (var i = 1; i <= HR_ZONES; i++) {
            if (rec["HrZ" + i] != null) { return true; }
        }
        return false;
    }

}

// --------------------------------------------------------------------------
// small helpers
// --------------------------------------------------------------------------

//! Collapse a zone vector to [Z1-2, Z3-4, Z5+].
//!
//! Both scales in use here are seven-zone. On Coggan power, Z3 is tempo and Z4
//! threshold -- together the grey band -- with VO2 and above from Z5. On the
//! seven-zone HR scale, Z4 is still sub-threshold and Z5 starts at roughly 97%
//! of LTHR. A five-zone split (Z4+ = hard) would count a lot of tempo work as
//! hard and flatter the high share considerably.
function toPolarized(pct as Array<Float>) as Array<Float> {
    var low = 0.0;
    var mid = 0.0;
    var high = 0.0;
    for (var i = 0; i < pct.size(); i++) {
        var v = pct[i];
        if (i < 2) { low += v; }
        else if (i < 4) { mid += v; }
        else { high += v; }
    }
    return [low, mid, high];
}

function zoneTotal(pct as Array<Float>) as Float {
    var t = 0.0;
    for (var i = 0; i < pct.size(); i++) { t += pct[i]; }
    return t;
}

function isoDate(moment as Time.Moment) as String {
    var i = Gregorian.info(moment, Time.FORMAT_SHORT);
    return i.year.format("%04d") + "-" + i.month.format("%02d") + "-" + i.day.format("%02d");
}

function str(v, fallback as String) as String {
    if (v instanceof Lang.String) { return v as String; }
    return fallback;
}

function flt(v, fallback as Float) as Float {
    if (v instanceof Lang.Float) { return v as Float; }
    if (v instanceof Lang.Number) { return (v as Number).toFloat(); }
    if (v instanceof Lang.Double) { return (v as Double).toFloat(); }
    return fallback;
}
