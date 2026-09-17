import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;

//! Layout helpers. Everything is expressed as a fraction of the screen so the
//! same code lays out correctly on the 416, 454 and 466 px round displays in
//! the fenix 9 family without a per-device layout file.
module Draw {

    const COL_BG = 0x000000;
    const COL_TEXT = 0xFFFFFF;
    const COL_DIM = 0x9A9A9A;
    const COL_TRACK = 0x2A2A2A;
    const COL_TICK = 0xFFFFFF;

    // Zone palettes. Mid-saturation on purpose: labels sit next to the bars,
    // not on them, but a fill this dark still reads on an AMOLED panel at a
    // glance in daylight.
    const POWER_COLORS = [
        0x6B7280, // Z1 recovery
        0x3B82F6, // Z2 endurance
        0x22C55E, // Z3 tempo
        0xF59E0B, // Z4 threshold
        0xEF4444, // Z5 vo2
        0xEC4899, // Z6 anaerobic
        0xA855F7  // Z7 neuromuscular
    ];

    // Seven-zone HR scale, same shape as the power palette so the two screens
    // read as one system.
    const HR_COLORS = [
        0x6B7280, // Z1 recovery
        0x3B82F6, // Z2 aerobic
        0x22C55E, // Z3 tempo
        0xF59E0B, // Z4 sub-threshold
        0xEF4444, // Z5 threshold
        0xEC4899, // Z6
        0xA855F7  // Z7
    ];

    // low / mid / high on the combined screen
    const POL_COLORS = [0x3B82F6, 0xF59E0B, 0xEF4444];

    //! Polarized reference: the shape the distribution is being checked against.
    const POL_TARGET = [80.0, 5.0, 15.0];

    //! Half the horizontal room available at vertical offset `dy` from the
    //! screen centre. On a round watch this shrinks towards the top and bottom,
    //! which is what keeps full-width bars from being clipped by the bezel.
    function halfWidthAt(dy as Float, radius as Float, isRound as Boolean) as Float {
        if (!isRound) { return radius; }
        var v = radius * radius - dy * dy;
        if (v <= 0.0) { return 0.0; }
        return Math.sqrt(v).toFloat();
    }

    //! Widest half-width safe for a band spanning [yTop, yBottom] -- takes the
    //! narrower of the two edges.
    function halfWidthForBand(yTop as Float, yBottom as Float, cy as Float,
                              radius as Float, isRound as Boolean) as Float {
        var a = halfWidthAt(yTop - cy, radius, isRound);
        var b = halfWidthAt(yBottom - cy, radius, isRound);
        return (a < b) ? a : b;
    }

    //! One labelled bar: "Z3" in a left gutter, a proportional track, and the
    //! percentage right-aligned in a right gutter.
    //! `target` < 0 draws no reference tick.
    function bar(dc as Graphics.Dc, label as String, pct as Float, color as Number,
                 y as Float, h as Float, cx as Float, half as Float,
                 labelW as Float, valueW as Float, target as Float) as Void {

        var left = cx - half;
        var right = cx + half;
        var trackX = left + labelW;
        var trackW = (right - valueW) - trackX;
        if (trackW < 12.0) { return; }

        var r = (h / 2.0).toNumber();
        var midY = y + h / 2.0;

        dc.setColor(COL_DIM, Graphics.COLOR_TRANSPARENT);
        dc.drawText(left, midY, Graphics.FONT_XTINY, label,
                    Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);

        dc.setColor(COL_TRACK, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(trackX.toNumber(), y.toNumber(),
                                trackW.toNumber(), h.toNumber(), r);

        var clamped = pct;
        if (clamped < 0.0) { clamped = 0.0; }
        if (clamped > 100.0) { clamped = 100.0; }
        var fillW = trackW * clamped / 100.0;
        if (fillW > 2.0) {
            dc.setColor(color, Graphics.COLOR_TRANSPARENT);
            dc.fillRoundedRectangle(trackX.toNumber(), y.toNumber(),
                                    fillW.toNumber(), h.toNumber(), r);
        }

        if (target >= 0.0) {
            var tx = trackX + trackW * target / 100.0;
            dc.setColor(COL_TICK, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(tx.toNumber(), (y - h * 0.25).toNumber(),
                             2, (h * 1.5).toNumber());
        }

        dc.setColor(COL_TEXT, Graphics.COLOR_TRANSPARENT);
        dc.drawText(right, midY, Graphics.FONT_XTINY, fmtPct(pct),
                    Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    function header(dc as Graphics.Dc, title as String, sub as String,
                    w as Number, h as Number) as Void {
        var cx = w / 2;
        dc.setColor(COL_TEXT, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.075, Graphics.FONT_TINY, title, Graphics.TEXT_JUSTIFY_CENTER);
        if (sub.length() > 0) {
            dc.setColor(COL_DIM, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, h * 0.145, Graphics.FONT_XTINY, sub, Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    function footer(dc as Graphics.Dc, text as String, w as Number, h as Number) as Void {
        dc.setColor(COL_DIM, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h * 0.855, Graphics.FONT_XTINY, text, Graphics.TEXT_JUSTIFY_CENTER);
    }

    //! Page indicator: three dots down the right edge.
    function pageDots(dc as Graphics.Dc, index as Number, count as Number,
                      w as Number, h as Number) as Void {
        var r = (w * 0.011).toNumber();
        if (r < 2) { r = 2; }
        var gap = r * 4;
        var x = (w * 0.965).toNumber();
        var y0 = h / 2 - ((count - 1) * gap) / 2;
        for (var i = 0; i < count; i++) {
            dc.setColor(i == index ? COL_TEXT : COL_TRACK, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(x, y0 + i * gap, r);
        }
    }

    function centreMessage(dc as Graphics.Dc, text as String, w as Number, h as Number) as Void {
        dc.setColor(COL_DIM, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h / 2, Graphics.FONT_SMALL, text,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    function fmtPct(v as Float) as String {
        if (v >= 99.95) { return "100%"; }
        return v.format("%.1f") + "%";
    }

    function fmtHours(v as Float) as String {
        return v.format("%.0f") + "h";
    }
}
