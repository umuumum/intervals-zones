import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

var gModel as Model or Null = null;

class ZonesApp extends Application.AppBase {

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state as Dictionary?) as Void {
        gModel = new Model();
        gModel.refresh(false);
    }

    function onStop(state as Dictionary?) as Void {
    }

    function getInitialView() {
        var view = new ZonesView();
        return [view, new ZonesDelegate(view)];
    }

    //! Fired when the phone pushes new Connect IQ settings.
    function onSettingsChanged() as Void {
        if (gModel != null) {
            gModel.loadSettings();
            gModel.refresh(true);
        }
    }
}
