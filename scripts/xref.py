#!/usr/bin/env python3
"""Cross-file reference check for the Swift port.

Declares nothing about correctness of the UIKit usage; it only answers one question:
does every capitalised identifier the code mentions exist somewhere in the project or in
a whitelisted system framework type? Catches the classic failure mode of a multi-agent
build: file A calls a type file B never wrote.
"""
import os, re, sys, collections

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "Flow")

SYSTEM = set("""
Foundation UIKit CoreGraphics CoreImage CoreMedia AVFoundation AVKit WebKit Photos
NSObject NSString NSArray NSDictionary NSNumber NSData NSDate NSURL NSURLSession NSURLRequest
NSLayoutConstraint NSLayoutAnchor NSLayoutXAxisAnchor NSLayoutYAxisAnchor NSLayoutDimension
NSAttributedString NSMutableAttributedString NSParagraphStyle NSMutableParagraphStyle
NSRegularExpression NSJSONSerialization NSNotification NSNotificationCenter NSUserDefaults
NSError NSCache NSCoder NSKeyedArchiver NSKeyedUnarchiver NSFileManager NSBundle NSLocale
NSTimeZone NSDateFormatter NSNumberFormatter NSByteCountFormatter NSMeasurement
NSOperationQueue NSBlockOperation NSThread NSUUID NSIndexPath NSRange NSSet NSOrderedSet
NSCountedSet NSPredicate NSSortDescriptor NSTimer NSLock NSRecursiveLock DispatchQueue
DispatchGroup DispatchSemaphore DispatchWorkItem OperationQueue Thread RunLoop Timer
URL URLRequest URLSession URLResponse HTTPURLResponse URLCache URLComponents
UIView UIViewController UINavigationController UITabBarController UITableViewController
UICollectionViewController UISplitViewController UIPageViewController UIScrollView
UITableView UITableViewCell UITableViewCellStyle UITableViewRowAnimation UITableViewDataSource
UITableViewDelegate UICollectionView UICollectionViewCell UICollectionViewLayout
UICollectionViewFlowLayout UICollectionViewDataSource UICollectionViewDelegate
UIStackView UILabel UIButton UIImage UIImageView UITextField UITextView UISearchBar
UISearchController UINavigationBar UITabBar UITabBarItem UIBarButtonItem UINavigationItem
UIActivityIndicatorView UIRefreshControl UIAlertController UIAlertAction UISlider
UISwitch UISegmentedControl UIPickerView UIDatePicker UIProgressView UIVisualEffectView
UIBlurEffect UIBezierPath UIColor UIFont UIImageRenderer UIGraphicsImageRenderer
UIGraphicsBeginImageContextWithOptions UIGraphicsGetImageFromCurrentImageContext
UIGraphicsEndImageContext UIScreen UIApplication UIWindow UIResponder UIEvent UITouch
UIGestureRecognizer UITapGestureRecognizer UIPanGestureRecognizer UILongPressGestureRecognizer
UISwipeGestureRecognizer UIPinchGestureRecognizer UIRotationGestureRecognizer
UIScreenEdgePanGestureRecognizer UIDevice UIDeviceOrientation UIInterfaceOrientation
UIViewPropertyAnimator UIViewAnimationOptions UIViewAnimationCurve
UIViewContentMode UIViewAutoresizing UIViewTintAdjustmentMode UISemanticContentAttribute
UIAccessibility UIAccessibilityTraits UIEdgeInsets UIOffset UIUserInterfaceStyle
UIStatusBarStyle UIApplicationDelegate UIApplicationLaunchOptionsKey
UIApplicationState UIBackgroundTaskIdentifier UIScene UIStoryboard UINib
UIViewControllerAnimatedTransitioning UIViewControllerTransitioningDelegate
UIViewControllerContextTransitioning UIPresentationController UIPopoverPresentationController
UIModalPresentationStyle UIModalTransitionStyle UIModalPresentationCustom
UIRectEdge UIRectCorner UICornerMask UILayoutPriority UILayoutGuide
UIScrollViewDelegate UITextFieldDelegate UITextViewDelegate UISearchBarDelegate
UISearchResultsUpdating UISearchControllerDelegate UIGestureRecognizerDelegate
UIPopoverController UIDocumentPickerViewController UIDocumentInteractionController
UIContextualAction UISwipeActionsConfiguration UIActivityViewController
UIApplicationShortcutItem UIUserNotificationSettings UILocalNotification
UIUserNotificationType UIMenuController UIMenuItem UIPasteboard
AVPlayer AVPlayerItem AVPlayerLayer AVPlayerViewController AVAsset AVURLAsset
AVMutableComposition AVMutableCompositionTrack AVAssetTrack AVMediaSelectionGroup
AVMediaSelectionOption AVPlayerItemTrack AVPlayerItemVideoOutput AVAudioSession
AVAudioEngine AVAudioPlayerNode AVAudioUnitEQ AVAudioMix AVAudioPCMBuffer
AVPictureInPictureController AVRoutePickerView AVRoutePickerViewButtonStyle
AVAudioTime AVAudioFormat AVAudioFile AVAudioRecorder AVAudioPlayer AVAudioNode
AVPlayerTimeControlStatus AVPictureInPictureControllerDelegate AVRoutePickerViewDelegate
MPNowPlayingInfoCenter MPNowPlayingInfoProperty MPRemoteCommandCenter MPRemoteCommand
MPMediaItemArtwork MPMediaItem
WKWebView WKWebViewConfiguration WKUserContentController WKScriptMessageHandler
WKNavigationDelegate WKNavigationAction WKNavigation
CAShapeLayer CALayer CAAnimation CABasicAnimation CAKeyframeAnimation CATransaction
CAGradientLayer CAReplicatorLayer CAMediaTimingFunction CATextLayer
CIImage CIContext CIFilter CIFilterBuiltins QRCodeGenerator
SQLite3 OpaquePointer sqlite3 sqlite3_stmt
JSONDecoder JSONEncoder JSONSerialization JSONSerializationReadingOptions
Codable Decodable Encodable CodableKey DecodingError EncodingError
Result Error Optional Array Dictionary Set String Int Int8 Int16 Int32 Int64 UInt UInt8
UInt16 UInt32 UInt64 Double Float CGFloat Bool Character Substring Void Any AnyObject
Equatable Hashable Comparable CustomStringConvertible CustomDebugStringConvertible
RawRepresentable CaseIterable Identifiable Sequence Collection IteratorProtocol
Numeric BinaryInteger FloatingPoint SignedInteger ClosedRange Range
Data DataSource TimeInterval Date Calendar DateComponents Locale
IndexSet CharacterSet Scanner NotificationCenter Notification
FileManager Bundle ProcessInfo
BundleIdentifier AnyClass Type Self
NSAttributedStringKey NSAttributedStringKeyFontAttributeName
NSFontAttributeName NSForegroundColorAttributeName NSParagraphStyleAttributeName
NSUnderlineStyle NSUnderlineStyleAttributeName NSBaselineOffsetAttributeName
NSShadow NSShadowAttributeName NSKernAttributeName NSLigatureAttributeName
CGRect CGPoint CGSize CGAffineTransform CGColor CGImage CGContext CGBitmapInfo
UIEdgeInsetsInsetRect CGRectInset CGRectOffset UIRectInset
UIGraphicsImageRendererFormat UIGraphicsImageRendererFormatRange UIGraphicsRendererFormat
NSLayoutConstraintOrientation UIDataDetectorTypes NSWritingDirection
UIViewKeyframeAnimationOptions UIViewAnimating UIViewAnimatingState UIViewImplicitlyAnimating
UIViewControllerPreviewing UIViewControllerPreviewingDelegate UIPreviewAction
UIApplicationOpenURLOptionsKey UIBackgroundFetchResult
AVAudioSessionCategory AVAudioSessionCategoryOptions AVAudioSessionMode
AVAudioSessionRouteChangeReason AVAudioSessionInterruptionType
MPNowPlayingInfoLanguageOption UIBarItem UIRefreshControl
NSHTTPURLResponse NSURLError NSURLErrorDomain NSLocalizedDescriptionKey
UIUserActivity UIUserActivityType
CLLocation CLLocationManager CLGeocoder
UniformTypeIdentifiers UTType
LocalizedError CustomNSError ErrorProtocol
DispatchTime DispatchQueueAttributes DispatchQoS DispatchQueueAutoreleaseFrequency
Timer TimerScheduledTimer
NSMutableURLRequest HTTPCookie HTTPCookieStorage HTTPCookiePropertyKey
NSHTTPCookieStorage NSHTTPCookieAcceptPolicy
SKStoreReviewController StoreKit
UNUserNotificationCenter UNNotificationRequest UNNotificationContent UNMutableNotificationContent
UNNotificationSettings UNUserNotificationSettings UNNotificationPresentationOptions
UNNotificationAction UNNotificationCategory UNNotificationSound
NSItemProvider UIActivityItemProvider UIActivityViewControllerCompletionWithItemsHandler
UIActivityItemSource
SystemSoundID AudioServicesPlaySystemSound AudioToolbox CoreAudio
Contacts CNContact
NSMeasurementFormatter NSLengthFormatter
UIScreenMode
NSProgress Progress
NSXPCConnection XPC
NSValue NSValueTransformer
CMTime CMTimeRange CMTimeMake CMTimeGetSeconds CMTimeMakeWithSeconds CMSampleBuffer
CMFormatDescription CMTIME
UIBezierPathAddRoundRect
Process ProcessInfo
NSOperation NSOperationQueue
NSFileCoordinator NSFilePresenter
NSXMLParser
NSCharacterSet
NSScanner
NSStream InputStream OutputStream
CVPixelBuffer CVPixelBufferRef
CVBuffer
CFTypeRef
DeterministicRandom
NSRandom
NSObjectProtocol
NSItemProviderWriting NSItemProviderReading
NSAttributedStringDocumentAttributeKey
UIImageSymbolConfiguration
UIStatusBarAnimation
UIApplicationDelegateWindow
NSLocalizedString
NSStringFromClass NSStringFromSelector
NSSelectorFromString
TargetAction
IBOutlet
NSUnknownKeyException
NSException
NSAssertionHandler
UIAccessibilityCustomAction UIAccessibilityElement
Encoder Decoder
FileHandle Pipe
NSAllowsArbitraryLoads
NSLayoutManager NSLocationInRange NSNull NSSearchPathForDirectoriesInDomains NSTemporaryDirectory
NSTextContainer NSTextStorage NSURLErrorBadURL NSURLErrorCancelled NSURLErrorCannotConnectToHost
NSURLErrorCannotFindHost NSURLErrorDataNotAllowed NSURLErrorInternationalRoamingOff
NSURLErrorNetworkConnectionLost NSURLErrorNotConnectedToInternet NSURLErrorTimedOut
SQLITE_BLOB SQLITE_DONE SQLITE_FLOAT SQLITE_INTEGER SQLITE_OK SQLITE_OPEN_CREATE SQLITE_OPEN_FULLMUTEX
SQLITE_OPEN_READWRITE SQLITE_ROW SQLITE_TEXT Selector Swift UIApplicationMain UICollectionReusableView
UICollectionViewDataSourcePrefetching UICollectionViewDelegateFlowLayout
UICollectionViewFlowLayoutInvalidationContext UICollectionViewLayoutInvalidationContext
UIFontMetrics UIGraphicsGetCurrentContext
AVAssetResourceLoader AVAssetResourceLoaderDelegate AVAssetResourceLoadingRequest
AVAudioSessionInterruptionOptionKey AVAudioSessionInterruptionTypeKey AVAudioSessionRouteChangeReasonKey
AVKeyValueStatus AVLayerVideoGravity AVMutableAudioMix AVMutableAudioMixInputParameters
CACornerMask CATransform3DMakeRotation CATransform3D CATransaction CMTimeMinimum CMTimeScale
CMTimeMapping CMTimeRangeMake CMTimeAdd CMTimeSubtract CMTimeCompare DateFormatter ISO8601DateFormatter
DispatchSource DispatchSourceTimer DispatchTimeNow DispatchWallTime DispatchWorkItemFlags
Element IndexPath MediaPlayer MTAudioProcessingTap MTAudioProcessingTapCallbacks MTAudioProcessingTapCreate
MTAudioProcessingTapFinalizeCallback MTAudioProcessingTapFlags MTAudioProcessingTapGetSourceAudio
MTAudioProcessingTapGetStorage MTAudioProcessingTapInitCallback MTAudioProcessingTapPrepareCallback
MTAudioProcessingTapProcessCallback MTAudioProcessingTapUnprepareCallback MediaToolbox MemoryLayout
MPChangePlaybackPositionCommandEvent MPMediaItemPropertyAlbumTitle MPMediaItemPropertyArtist
MPMediaItemPropertyArtwork MPMediaItemPropertyPlaybackDuration MPMediaItemPropertyTitle
MPNowPlayingInfoMediaType MPNowPlayingInfoPropertyElapsedPlaybackTime MPNowPlayingInfoPropertyMediaType
MPNowPlayingInfoPropertyPlaybackRate MPSkipIntervalCommandEvent MPVolumeView
NSEC_PER_SEC NSEC_PER_MSEC NSEC_PER_USEC NSKeyValueObservation NSKeyValueObservingOptions
NSKeyValueChangeKey NSLayoutConstraint NSAnimationContext NSAppKit
UIFontDescriptor UIFontDescriptorAttributeName UIFontDescriptorFeatureSettingsAttribute
UIFontWeight UIFontTextStyle UIContentSizeCategory UIFontDescriptorTraitKey
UIScrollViewKeyboardDismissMode UIScrollViewContentInsetAdjustmentBehavior
UITableViewStyle UITableViewSeparatorStyle UITableViewScrollPosition UITableViewCellAccessoryType
UIActivityType UIActivityCategory UIImageOrientation UIImageRenderingMode UIImageResizingMode
UIImagePickerController UIImagePickerControllerSourceType
UIDocumentPickerMode UIDocumentPickerViewController
UICollectionViewScrollPosition UICollectionViewScrollDirection
UIViewControllerTransitionCoordinator UIViewControllerTransitionCoordinatorContext
UIViewAnimationTransition UIViewAnimationState UIViewKeyframeAnimationOptions
UIApplicationBackgroundFetchInterval UIApplication.shared
UIBackgroundTaskIdentifier UIBackgroundFetchResult UIBackgroundTaskInvalid
UIKeyboardType UIKeyboardAppearance UIKeyboardAnimationCurveUserInfoKey
UIKeyboardFrameEndUserInfoKey UIKeyboardWillShowNotification UIKeyboardWillHideNotification
UIWindowLevel UIWindowSceneDelegate UIStatusBarStyle
AVAudioApplication AVAudioSessionRecordPermission
MPMediaLibrary MPMusicPlayerController
CGAffineTransformIdentity CGAffineTransformMakeRotation CGAffineTransformScale
CGContextRef CGColorSpace CGColorSpaceCreateDeviceRGB CGImageAlphaInfo CGBitmapInfoRawValue
CGRectMake CGPointMake CGSizeMake CGRectGetMaxY CGRectGetMaxX CGRectGetMinY CGRectGetMinX
CGRectGetMidY CGRectGetWidth CGRectGetHeight CGRectZero CGPointZero CGSizeZero
CACurrentMediaTime CATransform3DIdentity
NSAttributedStringKey NSMutableAttributedString
NSTextAlignment NSLineBreakMode NSWritingDirection
UISemanticContentAttribute UIAccessibilityPostNotification
NSString NSStringEncoding NSUTF8StringEncoding
NSURLComponents NSURLQueryItem
JSONDecoder KeyDecodingStrategy DateDecodingStrategy
CGImageDestination CGImageSource ImageIO
UIGraphicsImageRendererContext UIGraphicsRendererContext
UTType UTTypeIdentifier
AVAudioSessionCategoryPlayback AVAudioSessionCategoryAmbient
AVPlayerItemStatus AVPlayerStatus AVPlayerActionAtItemEnd
AVPlayerItemDidPlayToEndTimeNotification AVPlayerItemFailedToPlayToEndTimeNotification
AVPlayerItemNewErrorLogEntryNotification
AVAssetImageGenerator AVAssetImageGeneratorCompletionHandler
AVMediaType AVMediaTypeVideo AVMediaTypeAudio
AVFileType AVFileTypeMPEG4
AVAudioSessionSilenceSecondaryAudioHintType
UIFeedbackGenerator UIImpactFeedbackGenerator UISelectionFeedbackGenerator UINotificationFeedbackGenerator
UIImpactFeedbackStyle UINotificationFeedbackType
ProMotion
NSCalendar NSDateComponents NSDateComponentsFormatter
NumberFormatter Formatter
CodingKeys
DecodingStrategy EncodingStrategy
""".split())

def strip_literals(text):
    text = re.sub(r'"""(?:.|\n)*?"""', '""', text)
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    text = re.sub(r"//[^\n]*", " ", text)
    text = re.sub(r'"(?:[^"\\\n]|\\.)*"', '""', text)
    return text

def main():
    files = [os.path.join(b, f) for b, _, fs in os.walk(SRC) for f in fs if f.endswith(".swift")]
    declared = set()
    bodies = {}
    for p in files:
        raw = open(p, encoding="utf-8", errors="replace").read()
        t = strip_literals(raw)
        bodies[p] = t
        for m in re.finditer(r"\b(?:class|struct|enum|protocol|typealias|actor)\s+([A-Z][A-Za-z0-9_]*)", t):
            declared.add(m.group(1))
        for m in re.finditer(r"\bextension\s+([A-Z][A-Za-z0-9_]*)", t):
            declared.add(m.group(1))
    missing = collections.defaultdict(set)
    for p, t in bodies.items():
        for m in re.finditer(r"(?<![.\w])([A-Z][A-Za-z0-9_]{2,})\b", t):
            name = m.group(1)
            if name in declared or name in SYSTEM:
                continue
            missing[name].add(os.path.relpath(p, ROOT))
    if not missing:
        print("no undeclared identifiers")
        return 0
    print("undeclared identifiers: %d" % len(missing))
    for name in sorted(missing):
        print("  %-40s %s" % (name, ", ".join(sorted(missing[name])[:3])))
    return 1

if __name__ == "__main__":
    sys.exit(main())
