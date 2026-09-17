import Toybox.Lang;
import Toybox.WatchUi;

//! Up/down (swipe on touch, UP/DOWN keys on a fenix) pages between the three
//! screens. START/ENTER forces a refresh.
class ZonesDelegate extends WatchUi.BehaviorDelegate {

    private var _view as ZonesView;

    function initialize(view as ZonesView) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    function onNextPage() as Boolean {
        _view.nextPage();
        return true;
    }

    function onPreviousPage() as Boolean {
        _view.prevPage();
        return true;
    }

    function onSelect() as Boolean {
        if (gModel != null) {
            gModel.refresh(true);
        }
        return true;
    }

    //! Some devices report the vertical swipe as a swipe rather than a page
    //! behavior, so handle both.
    function onSwipe(event as WatchUi.SwipeEvent) as Boolean {
        var d = event.getDirection();
        if (d == WatchUi.SWIPE_UP) {
            _view.nextPage();
            return true;
        }
        if (d == WatchUi.SWIPE_DOWN) {
            _view.prevPage();
            return true;
        }
        return false;
    }
}
