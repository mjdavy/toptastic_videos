import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // SCREENSHOT MODE: Uncomment ONE of these lines to set window size for App Store screenshots
    // Then take screenshot with Cmd+Shift+4, press Space, click window
    // Remember to comment out again before releasing!
    
    //setContentSize(NSSize(width: 1280, height: 800))   // 13" MacBook
    // setContentSize(NSSize(width: 1440, height: 900))   // 13" MacBook Pro
    //setContentSize(NSSize(width: 2560, height: 1600))  // 13" Retina
    //setContentSize(NSSize(width: 2880, height: 1800))  // 15" Retina

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
