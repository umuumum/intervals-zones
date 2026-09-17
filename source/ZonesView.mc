import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

//! One view, three pages. Up/down (swipe or buttons) moves between them.
class ZonesView extends WatchUi.View {

    public static const PAGE_POWER = 0;
    public static const PAGE_HR = 1;
    public static const PAGE_POLARIZED = 2;
    public static const PAGE_COUNT = 3;

    public var page as Number = PAGE_POWER;

    private var _isRound as Boolean = true;

    function initialize() {
        View.initialize();
    }

    function onLayout(dc as Graphics.Dc) as Void {
        var s = System.getDeviceSettings();
        _isRound = (s.screenShape == System.SCREEN_SHAPE_ROUND);
    }

    function nextPage() as Void {
        page = (page + 1) % PAGE_COUNT;
        WatchUi.requestUpdate();
    }

    function prevPage() as Void {
        page = (page + PAGE_COUNT - 1) % PAGE_COUNT;
        WatchUi.requestUpdate();
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();

        dc.setColor(Draw.COL_BG, Draw.COL_BG);
        dc.clear();

        var m = gModel;
        if (m == null) {
            Draw.centreMessage(dc, "…", w, h);
            return;
        }

        if (!m.hasData) {
            if (m.error != null) {
                Draw.centreMessage(dc, m.error, w, h);
            } else if (m.loading) {
                Draw.centreMessage(dc, "Loading…", w, h);
            } else {
                Draw.centreMessage(dc, "No data", w, h);
            }
            return;
        }

        if (page == PAGE_POWER) {
            drawZonePage(dc, w, h, "POWER", m.powerPct, Draw.POWER_COLORS, m.powerHours);
        } else if (page == PAGE_HR) {
            drawZonePage(dc, w, h, "HEART RATE", m.hrPct, Draw.HR_COLORS, m.hrHours);
        } else {
            drawPolarizedPage(dc, w, h, m);
        }

        Draw.pageDots(dc, page, PAGE_COUNT, w, h);
    }

    // ----------------------------------------------------------------------

    private function drawZonePage(dc as Graphics.Dc, w as Number, h as Number,
                                  title as String, pct as Array<Float>,
                                  colors as Array<Number>, hours as Float) as Void {

        var n = pct.size();
        if (zoneTotal(pct) <= 0.0) {
            Draw.header(dc, title, "42 days", w, h);
            Draw.centreMessage(dc, "no time\nrecorded", w, h);
            Draw.footer(dc, statusLine(), w, h);
            return;
        }

        var headBottom = Draw.header(dc, title, "42 days · " + Draw.fmtHours(hours), w, h);

        var cx = w / 2.0;
        var cy = h / 2.0;
        var radius = w / 2.0 - w * 0.06;
        var labelW = w * 0.105;
        var valueW = w * 0.16;

        var yTop = headBottom + h * 0.020;
        var yBot = Draw.footerTop(dc, h) - h * 0.015;
        var pitch = (yBot - yTop) / n;
        var barH = pitch * 0.64;
        if (barH < 8.0) { barH = 8.0; }

        for (var i = 0; i < n; i++) {
            var y = yTop + i * pitch + (pitch - barH) / 2.0;
            var half = Draw.halfWidthForBand(y, y + barH, cy, radius, _isRound);
            Draw.bar(dc, "Z" + (i + 1), pct[i], colors[i],
                     y, barH, cx, half, labelW, valueW, -1.0);
        }

        Draw.footer(dc, statusLine(), w, h);
    }

    // ----------------------------------------------------------------------

    private function drawPolarizedPage(dc as Graphics.Dc, w as Number, h as Number,
                                       m as Model) as Void {

        var p = toPolarized(m.powerPct);
        var hr = toPolarized(m.hrPct);
        var names = ["Z1-2  easy", "Z3-4  grey zone", "Z5+  hard"];

        var headBottom = Draw.header(dc, "POLARIZED", "P / H  vs 80·5·15", w, h);

        var cx = w / 2.0;
        var cy = h / 2.0;
        var radius = w / 2.0 - w * 0.06;
        var labelW = w * 0.075;
        var valueW = w * 0.16;

        var yTop = headBottom + h * 0.022;
        var yBot = Draw.footerTop(dc, h) - h * 0.015;
        var groupPitch = (yBot - yTop) / 3.0;

        // Measured, not guessed: the group caption gets its real height plus a
        // deliberate gap, and the two bars split whatever is left. Deriving the
        // caption height from the pitch is what let the bars ride up over it.
        var headH = dc.getFontHeight(Graphics.FONT_XTINY).toFloat();
        var gapAfterHead = h * 0.008;
        var gapBetweenBars = h * 0.010;
        var gapBetweenGroups = h * 0.020;
        var barH = (groupPitch - headH - gapAfterHead
                    - gapBetweenBars - gapBetweenGroups) / 2.0;
        if (barH < 8.0) { barH = 8.0; }

        for (var g = 0; g < 3; g++) {
            var gy = yTop + g * groupPitch;

            dc.setColor(Draw.COL_DIM, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, gy, Graphics.FONT_XTINY, names[g], Graphics.TEXT_JUSTIFY_CENTER);

            var y1 = gy + headH + gapAfterHead;
            var y2 = y1 + barH + gapBetweenBars;

            var half1 = Draw.halfWidthForBand(y1, y1 + barH, cy, radius, _isRound);
            var half2 = Draw.halfWidthForBand(y2, y2 + barH, cy, radius, _isRound);

            Draw.bar(dc, "P", p[g], Draw.POL_COLORS[g], y1, barH, cx, half1,
                     labelW, valueW, Draw.POL_TARGET[g]);
            Draw.bar(dc, "H", hr[g], Draw.POL_COLORS[g], y2, barH, cx, half2,
                     labelW, valueW, Draw.POL_TARGET[g]);
        }

        Draw.footer(dc, statusLine(), w, h);
    }

    // ----------------------------------------------------------------------

    private function statusLine() as String {
        var m = gModel;
        if (m == null) { return ""; }
        if (m.loading) { return "refreshing…"; }
        var age = m.ageMinutes();
        if (age < 0) { return m.dataDate; }
        if (age < 60) { return age + "m ago"; }
        if (age < 1440) { return (age / 60) + "h ago"; }
        return (age / 1440) + "d ago";
    }
}
