# Foundation API surface (generated)


## Flow/Core/Util/Extensions.swift
extension UIColor {
func mixed(with other: UIColor, amount: CGFloat) -> UIColor {
func channel(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
func opaqueOver(_ ground: UIColor) -> UIColor {
func linear(_ value: CGFloat) -> CGFloat {
static func contrastRatio(_ first: UIColor, _ second: UIColor) -> CGFloat {
func adjustedForContrast(against background: UIColor, ratio: CGFloat) -> UIColor {
func withAlpha(_ alpha: CGFloat) -> UIColor {
extension CGFloat {
func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
func roundedToPixel(scale: CGFloat = UIScreen.main.scale) -> CGFloat {
extension UIView {
func addSubviewForAutoLayout(_ subview: UIView) {
func pinEdges(of subview: UIView, insets: UIEdgeInsets = .zero) {
func applyCornerRadius(_ radius: CGFloat, maskedCorners: CACornerMask? = nil) {
func applyBackground(_ color: UIColor) {
func fadeIn(duration: TimeInterval = FlowMotion.standard) {
static func hairline() -> UIView {
extension UIViewController {
func flowPresent(_ controller: UIViewController, animated: Bool = true, completion: (() -> Void)? = nil) {
extension UIEdgeInsets {
static func all(_ value: CGFloat) -> UIEdgeInsets {
static func horizontal(_ horizontal: CGFloat, vertical: CGFloat) -> UIEdgeInsets {
extension String {
func truncated(to limit: Int) -> String {
extension Optional where Wrapped == String {
extension Array {
func element(at index: Int) -> Element? {
extension Collection {
extension Int {
extension TimeInterval {
extension Date {
func addingDays(_ days: Int) -> Date {
extension Notification.Name {

## Flow/Core/Util/Formatters.swift
enum Formatters {
static func compactCount(_ value: Int) -> String {
static func groupedCount(_ value: Int) -> String {
static func viewCount(_ value: Int) -> String {
static func subscriberCount(_ value: Int) -> String {
static func playbackTime(_ seconds: TimeInterval) -> String {
static func durationBadge(_ seconds: TimeInterval?) -> String? {
static func longDuration(_ seconds: TimeInterval) -> String {
static func relativeDate(_ date: Date, now: Date = Date()) -> String {
static func absoluteDate(_ date: Date) -> String {
static func historyDate(_ date: Date, now: Date = Date()) -> String {
static func dayHeading(_ date: Date) -> String {
static func fileSize(_ bytes: Int64) -> String {
static func playbackSpeed(_ speed: Double) -> String {
static func percent(_ fraction: Double) -> String {

## Flow/Core/Util/Observable.swift
final class ObservationToken {
private var cancel: (() -> Void)?
func cancelObservation() {
final class FlowObservable<Value> {
private var valueStorage: Value
func set(_ newValue: Value) {
func setSilently(_ newValue: Value) {
func mutate(_ transform: (inout Value) -> Void) {
func observe(_ handler: @escaping (Value) -> Void) -> ObservationToken {
func observeChanges(_ handler: @escaping (Value) -> Void) -> ObservationToken {
private func removeObserver(_ identifier: UUID) {
private func deliver(_ newValue: Value, to handlers: [(Value) -> Void]) {
final class FlowEventBus {
func on(_ name: String, handler: @escaping (Any?) -> Void) -> ObservationToken {
func post(_ name: String, payload: Any? = nil) {
func broadcast(_ name: String, notification: Notification.Name, payload: Any? = nil) {
final class ObservationBag {
func add(_ token: ObservationToken) {
func cancelAll() {
final class FlowDebouncer {
private let interval: TimeInterval
private var pending: DispatchWorkItem?
func schedule(_ action: @escaping () -> Void) {
func cancel() {
final class FlowCoalescer {
private let action: () -> Void
func trigger() {

## Flow/Core/UI/AsyncImageView.swift
final class AsyncImageView: UIImageView {
private var targetSize: CGSize?
private func commonInit() {
func setImage(url: String?, placeholder: UIColor? = nil) {
func setImage(url: String?, targetSize size: CGSize) {
func clearImage() {
func applyTheme() {
private func apply(_ loaded: UIImage?, for url: String) {
private func cancelCurrentRequest() {
private func updatePlaceholder() {
override func layoutSubviews() {
static func make(contentMode: UIView.ContentMode = .scaleAspectFill, cornerRadius: CGFloat = 0.0) -> AsyncImageView {

## Flow/Core/UI/FlowButton.swift
enum FlowButtonStyle {
final class FlowButton: UIControl {
private var icon: FlowIcon?
var onTap: (() -> Void)?
private func commonInit() {
static func make(_ title: String, style: FlowButtonStyle = .filled, icon: FlowIcon? = nil) -> FlowButton {
static func makeIcon(_ icon: FlowIcon, style: FlowButtonStyle = .text) -> FlowButton {
func configure(title: String, style: FlowButtonStyle, icon: FlowIcon? = nil) {
func setTitle(_ title: String) {
func setIcon(_ icon: FlowIcon?) {
func setLoading(_ loading: Bool) {
func applyTheme() {
override func layoutSubviews() {
extension FlowIcon {
static func accessibilityName(for icon: FlowIcon) -> String {

## Flow/Core/UI/FlowCard.swift
final class FlowCard: UIView {
enum Elevation {
func color(in scheme: FlowColorScheme) -> UIColor {
private func commonInit() {
static func make(elevation: Elevation = .standard, cornerRadius: CGFloat = FlowShapes.card) -> FlowCard {
func setContentInsets(_ insets: UIEdgeInsets) {
func setShowsOutline(_ shows: Bool) {
func applyTheme() {
func makeTappable(target: Any?, action: Selector) {
final class FlowSectionHeader: UIView {
var onAction: (() -> Void)?
private func commonInit() {
static func make(title: String, subtitle: String? = nil, actionTitle: String? = nil) -> FlowSectionHeader {
func configure(title: String, subtitle: String? = nil, actionTitle: String? = nil) {
func setActionTitle(_ title: String?) {
func applyTheme() {
final class FlowShelf: UIView {
private func commonInit() {
func configure(title: String, subtitle: String? = nil, actionTitle: String? = nil) {
func setItems(_ views: [UIView]) {
func addItem(_ view: UIView) {
func applyTheme() {
final class FlowVideoCard: UIControl {
private var progressWidth: NSLayoutConstraint?
var onTap: (() -> Void)?
private var widthConstraint: NSLayoutConstraint?
private func commonInit() {
func configure(with video: Video, showsAvatar: Bool = false) {
func configure(with entry: HistoryEntry) {
func setProgress(_ value: Double) {
override func layoutSubviews() {
func applyTheme() {
final class PaddedLabel: UILabel {
override func drawText(in rect: CGRect) {
override func sizeThatFits(_ size: CGSize) -> CGSize {

## Flow/Core/UI/FlowChip.swift
final class FlowChip: UIControl {
private var icon: FlowIcon?
var onTap: (() -> Void)?
private func commonInit() {
static func make(_ title: String, selected: Bool = false, icon: FlowIcon? = nil) -> FlowChip {
func configure(title: String, selected: Bool, icon: FlowIcon? = nil) {
func setSelected(_ selected: Bool, animated: Bool = true) {
private func updateSelectionTraits() {
override func layoutSubviews() {
func applyTheme() {
final class FlowChipRow: UIView {
var onSelect: ((Int) -> Void)?
private func commonInit() {
func setTitles(_ titles: [String], selectedIndex: Int = 0) {
func select(index: Int) {
func applyTheme() {
final class FlowBadge: UIView {
private func commonInit() {
static func make(_ text: String) -> FlowBadge {
func setText(_ text: String) {
override func layoutSubviews() {
func applyTheme() {

## Flow/Core/UI/FlowEmptyState.swift
final class FlowEmptyState: UIView {
enum Kind {
var onAction: (() -> Void)?
private func commonInit() {
static func make(kind: Kind, actionTitle: String? = nil) -> FlowEmptyState {
func configure(kind: Kind, actionTitle: String? = nil) {
let content: (FlowIcon, String, String)
func applyTheme() {
final class FlowErrorRow: UIView {
var onRetry: (() -> Void)?
private func commonInit() {
func configure(message: String) {
func applyTheme() {

## Flow/Core/UI/FlowIcon.swift
struct FlowIconDrawing {
func image(size: CGFloat, color: UIColor = .black) -> UIImage {
enum FlowIcon: String, CaseIterable {
func image(size: CGFloat, color: UIColor = .black) -> UIImage {
static func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
static func line(_ points: [CGPoint]) -> UIBezierPath {
static func circle(_ center: CGPoint, _ radius: CGFloat) -> UIBezierPath {
static func arc(_ center: CGPoint, _ radius: CGFloat, _ startDegrees: CGFloat, _ endDegrees: CGFloat, clockwise: Bool = true) -> UIBezierPath {
static func triangle(center: CGPoint, width: CGFloat, height: CGFloat) -> UIBezierPath {
static func triangleFlipped(center: CGPoint, width: CGFloat, height: CGFloat) -> UIBezierPath {
static func heartPath() -> UIBezierPath {
static func thumbsPath(pointingUp: Bool) -> UIBezierPath {
final class FlowIconView: UIView {
var badgeColor: UIColor?
private func commonInit() {
static func make(_ icon: FlowIcon, color: UIColor, size: CGFloat = 24.0) -> FlowIconView {
override func draw(_ rect: CGRect) {
override func didMoveToWindow() {
final class FlowIconButton: UIButton {
private func commonInit() {
static func make(_ icon: FlowIcon, color: UIColor, size: CGFloat = 24.0, target: Any?, action: Selector) -> FlowIconButton {
func configure(icon: FlowIcon, color: UIColor, size: CGFloat = 24.0) {
func setIcon(_ icon: FlowIcon) {
func setIconColor(_ color: UIColor) {

## Flow/Core/UI/FlowInsetGroupedTable.swift
final class FlowInsetGroupedTable: UITableView {
private func commonInit() {
func applyTheme() {
override func layoutSubviews() {
override func reloadData() {
private func updateCardFrames() {
let card: UIView
final class FlowInsetGroupedCell: UITableViewCell {
private var iconWidth: NSLayoutConstraint?
private var iconLeading: NSLayoutConstraint?
private func commonInit() {
func configure(icon: FlowIcon?, title: String, subtitle: String? = nil, value: String? = nil) {
private func updateIcon() {
func applyTheme() {
override func prepareForReuse() {
final class FlowInsetGroupedHeader: UITableViewHeaderFooterView {
private func commonInit() {
func configure(title: String) {
func applyTheme() {

## Flow/Core/UI/FlowListDiff.swift
struct FlowListDiff<Element: Hashable> {
let deletions: [Int]
let insertions: [Int]
let moves: [(from: Int, to: Int)]
let reloads: [Int]
static func between(old: [Element], new: [Element], changed: Set<Element> = []) -> FlowListDiff {
func deletionIndexPaths(section: Int = 0) -> [IndexPath] {
func insertionIndexPaths(section: Int = 0) -> [IndexPath] {
func reloadIndexPaths(section: Int = 0) -> [IndexPath] {
private struct Match {
let oldIndex: Int
let newIndex: Int
private static func longestCommonSubsequence(_ old: [Element], _ new: [Element]) -> [Match] {
extension UITableView {
func applyDiff<Element: Hashable>(
extension UICollectionView {
func applyDiff<Element: Hashable>(

## Flow/Core/UI/FlowSegmentedTabs.swift
final class FlowSegmentedTabs: UIView {
private var indicatorLeading: NSLayoutConstraint?
private var indicatorWidth: NSLayoutConstraint?
var onSelect: ((Int) -> Void)?
private func commonInit() {
func setTitles(_ titles: [String], selectedIndex: Int = 0) {
func select(index: Int, notify: Bool) {
private func updateIndicator(animated: Bool) {
override func layoutSubviews() {
func applyTheme() {
final class FlowSegmentedControl: UIControl {
private var thumbLeading: NSLayoutConstraint?
private var thumbWidth: NSLayoutConstraint?
var onSelect: ((Int) -> Void)?
private func commonInit() {
func setTitles(_ titles: [String], selectedIndex: Int = 0) {
func select(index: Int) {
private func updateThumb(animated: Bool) {
override func layoutSubviews() {
func applyTheme() {

## Flow/Core/UI/FlowSheet.swift
final class FlowSheet: UIViewController, UIGestureRecognizerDelegate {
enum Detent {
private let contentView: UIView
private let detent: Detent
private let showsGrabber: Bool
private var sheetHeight: NSLayoutConstraint?
private var sheetBottom: NSLayoutConstraint?
private var panGesture: UIPanGestureRecognizer?
var onDismiss: (() -> Void)?
override func viewDidLoad() {
override func viewDidLayoutSubviews() {
let height: CGFloat
override func viewWillAppear(_ animated: Bool) {
override func viewDidAppear(_ animated: Bool) {
func present(from presenter: UIViewController? = nil, animated: Bool = true) {
func dismissSheet(animated: Bool = true) {
func applyTheme() {
func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
private func scrollViewAt(point: CGPoint, in root: UIView) -> UIScrollView? {
static func topViewController() -> UIViewController? {
final class FlowActionSheetContent: UIView {
struct Action {
let title: String
let icon: FlowIcon?
let isDestructive: Bool
let handler: () -> Void
var onActionSelected: (() -> Void)?
private func makeRow(_ action: Action) -> UIControl {
func applyTheme() {
final class ControlClosure: NSObject {
private let closure: () -> Void
extension UIControl {
func addClosureActionForControl(for controlEvents: UIControl.Event, _ closure: @escaping () -> Void) {

## Flow/Core/UI/FlowShimmer.swift
final class FlowShimmerView: UIView {
private var bandLeading: NSLayoutConstraint?
private func commonInit() {
static func make(width: CGFloat? = nil, height: CGFloat, radius: CGFloat = FlowShapes.extraSmall) -> FlowShimmerView {
func applyTheme() {
func startAnimating() {
private func loop() {
func stopAnimating() {
override func didMoveToWindow() {
final class FlowShimmerCard: UIView {
private func commonInit() {
func startAnimating() {
func stopAnimating() {
func applyTheme() {
final class FlowShimmerGrid: UIView {
private func commonInit() {
func setRowCount(_ count: Int) {
func startAnimating() {
func stopAnimating() {
func applyTheme() {

## Flow/Core/UI/FlowSnackbar.swift
final class FlowSnackbar {
private var current: UIView?
private var dismissWorkItem: DispatchWorkItem?
static func show(_ message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
static func showError(_ message: String) {
private func enqueue(message: String, actionTitle: String?, action: (() -> Void)?) {
private func presentNext() {
var actionButton: UIButton?
private func dismissCurrent() {
private static func topViewController() -> UIViewController? {
final class ClosureAction: NSObject {
private let closure: () -> Void
extension UIButton {
func addClosureAction(for controlEvents: UIControl.Event, _ closure: @escaping () -> Void) {

## Flow/Core/UI/ImageLoader.swift
final class ImageLoader {
private final class Entry {
let image: UIImage
let cost: Int
private let session: URLSession
private let directory: URL
func cachedImage(for urlString: String) -> UIImage? {
func load(_ urlString: String, completion: @escaping (UIImage?) -> Void) {
func load(_ urlString: String, targetSize: CGSize, completion: @escaping (UIImage?) -> Void) {
func prefetch(_ urlStrings: [String]) {
func clearMemory() {
func clearDisk() {
func diskSize() -> Int64 {
private func fetch(urlString: String, path: URL) {
private func finish(urlString: String, image: UIImage?) {
private func diskPath(for urlString: String) -> URL {
func trimDiskCache() {
static func downsample(_ image: UIImage, to size: CGSize) -> UIImage {
static func placeholderColor(for urlString: String, in scheme: FlowColorScheme) -> UIColor {

## Flow/Core/Storage/DownloadStore.swift
enum DownloadState: String {
struct DownloadRecord {
let videoId: String
let title: String
let channelName: String
let thumbnailUrl: String
let filePath: String
let audioPath: String
let quality: String
let byteSize: Int64
let duration: TimeInterval
let state: DownloadState
let progress: Double
let createdAt: Date
let isMusic: Bool
final class DownloadStore {
private let database: FlowDB
func all() -> [DownloadRecord] {
func completed() -> [DownloadRecord] {
func active() -> [DownloadRecord] {
func record(videoId: String) -> DownloadRecord? {
func isDownloaded(videoId: String) -> Bool {
func isDownloading(videoId: String) -> Bool {
func storageUsed() -> Int64 {
func enqueue(
func updateProgress(videoId: String, progress: Double, byteSize: Int64) {
func complete(videoId: String, filePath: String, audioPath: String, byteSize: Int64) {
func fail(videoId: String) {
func pause(videoId: String) {
func resume(videoId: String) {
func remove(videoId: String) {
func removeAll() {
func nextQueued() -> DownloadRecord? {
private func markInterruptedDownloads() {
private static func deleteFiles(for record: DownloadRecord) {
private static func record(from row: FlowDBRow) -> DownloadRecord {

## Flow/Core/Storage/FlowDB.swift
enum FlowDBValue {
static func int(_ value: Int) -> FlowDBValue {
static func bool(_ value: Bool) -> FlowDBValue {
static func double(_ value: Double) -> FlowDBValue {
static func string(_ value: String?) -> FlowDBValue {
static func date(_ value: Date?) -> FlowDBValue {
struct FlowDBRow {
private let storage: [String: FlowDBValue]
func value(_ column: String) -> FlowDBValue {
func int(_ column: String) -> Int {
func int64(_ column: String) -> Int64 {
func double(_ column: String) -> Double {
func bool(_ column: String) -> Bool {
func string(_ column: String) -> String {
func optionalString(_ column: String) -> String? {
func date(_ column: String) -> Date? {
func data(_ column: String) -> Data? {
final class FlowDB {
struct Failure: Error, CustomStringConvertible {
let message: String
let code: Int32
private var handle: OpaquePointer?
private let path: String
private func openLocked() {
var database: OpaquePointer?
private func migrateLocked() {
func execute(_ statement: String, _ arguments: [FlowDBValue] = []) -> Int {
func transaction(_ body: (FlowDBTransaction) -> Void) -> Bool {
func query(_ statement: String, _ arguments: [FlowDBValue] = []) -> [FlowDBRow] {
func firstRow(_ statement: String, _ arguments: [FlowDBValue] = []) -> FlowDBRow? {
func scalarInt(_ statement: String, _ arguments: [FlowDBValue] = []) -> Int {
func eraseAll() {
fileprivate func executeLocked(_ statement: String, _ arguments: [FlowDBValue]) -> Int {
var prepared: OpaquePointer?
fileprivate func executeRaw(_ statement: String) {
var prepared: OpaquePointer?
fileprivate func queryLocked(_ statement: String, _ arguments: [FlowDBValue]) -> [FlowDBRow] {
var prepared: OpaquePointer?
private func readValue(_ statement: OpaquePointer, _ index: Int32) -> FlowDBValue {
private func bind(_ arguments: [FlowDBValue], to statement: OpaquePointer, database: OpaquePointer) {
final class FlowDBTransaction {
private let database: FlowDB
private let queue: DispatchQueue
func fail() {
func execute(_ statement: String, _ arguments: [FlowDBValue] = []) -> Int {
func query(_ statement: String, _ arguments: [FlowDBValue] = []) -> [FlowDBRow] {

## Flow/Core/Storage/HistoryStore.swift
struct HistoryEntry {
let videoId: String
let title: String
let channelId: String
let channelName: String
let thumbnailUrl: String
let duration: TimeInterval
let position: TimeInterval
let watchedAt: Date
let isMusic: Bool
final class HistoryStore {
private let database: FlowDB
func recent(limit: Int = 100, musicOnly: Bool = false) -> [HistoryEntry] {
func search(_ query: String, limit: Int = 100) -> [HistoryEntry] {
func groupedByDay(limit: Int = 500) -> [(day: Date, entries: [HistoryEntry])] {
func resumePosition(for videoId: String) -> TimeInterval? {
func contains(videoId: String) -> Bool {
func topChannels(limit: Int = 10) -> [(channelId: String, channelName: String, watches: Int)] {
func totalWatchTime(since: Date? = nil) -> TimeInterval {
let rows: [FlowDBRow]
func watchTimeByDay(days: Int = 7) -> [(day: Date, seconds: TimeInterval)] {
func record(
func updatePosition(videoId: String, position: TimeInterval, duration: TimeInterval) {
func remove(videoId: String) {
func clear() {
func removeOlderThan(_ date: Date) {
func prune(maximum: Int = 5000) {
private func reloadCache() {
private static func entry(from row: FlowDBRow) -> HistoryEntry {
final class SearchHistoryStore {
private let database: FlowDB
func recent(limit: Int = 12) -> [String] {
func record(_ query: String) {
func remove(_ query: String) {
func clear() {

## Flow/Core/Storage/NoteStore.swift
struct VideoNote {
let id: Int64
let videoId: String
let videoTitle: String
let channelName: String
let body: String
let timestamp: TimeInterval
let createdAt: Date
let updatedAt: Date
final class NoteStore {
private let database: FlowDB
func all() -> [VideoNote] {
func notes(for videoId: String) -> [VideoNote] {
func note(id: Int64) -> VideoNote? {
func search(_ query: String) -> [VideoNote] {
func count(for videoId: String) -> Int {
func create(
func update(id: Int64, body: String) {
func move(id: Int64, to timestamp: TimeInterval) {
func delete(id: Int64) {
func deleteAll(for videoId: String) {
func deleteAll() {
private static func note(from row: FlowDBRow) -> VideoNote {
final class SavedShortsStore {
private let database: FlowDB
func all() -> [(videoId: String, title: String, channelName: String, thumbnailUrl: String, savedAt: Date)] {
func contains(videoId: String) -> Bool {
func toggle(videoId: String, title: String, channelName: String, thumbnailUrl: String) -> Bool {
func remove(videoId: String) {
func clear() {
final class TopicStore {
private let database: FlowDB
func topTopics(limit: Int = 20) -> [(token: String, weight: Double)] {
func weight(of token: String) -> Double {
func learn(title: String, channelName: String, weight: Double = 1.0) {
func score(title: String, channelName: String) -> Double {
func reset() {
static func tokenize(_ text: String) -> [String] {

## Flow/Core/Storage/PlaylistStore.swift
struct PlaylistEntry {
let rowId: Int64
let playlistId: String
let videoId: String
let title: String
let channelName: String
let thumbnailUrl: String
let duration: TimeInterval
let position: Int
let addedAt: Date
struct StoredPlaylist {
let playlistId: String
let title: String
let description: String
let thumbnailUrl: String
let isLocal: Bool
let createdAt: Date
let updatedAt: Date
var items: [PlaylistEntry]
final class PlaylistStore {
private let database: FlowDB
func allPlaylists() -> [StoredPlaylist] {
func localPlaylists() -> [StoredPlaylist] {
func playlist(id: String) -> StoredPlaylist? {
func items(in playlistId: String) -> [PlaylistEntry] {
func itemCount(in playlistId: String) -> Int {
func playlistsContaining(videoId: String) -> [String] {
func contains(videoId: String, in playlistId: String) -> Bool {
func createPlaylist(title: String, description: String = "") -> String {
func saveRemotePlaylist(
func addVideo(
func removeVideo(videoId: String, from playlistId: String) {
func removeItem(rowId: Int64, from playlistId: String) {
func moveItem(in playlistId: String, from: Int, to: Int) {
func renamePlaylist(id: String, title: String) {
func updateDescription(id: String, description: String) {
func deletePlaylist(id: String) {
func deleteAllLocalPlaylists() {
private func renumber(playlistId: String, transaction: FlowDBTransaction) {

## Flow/Core/Storage/PrefsStore.swift
final class PrefsStore {
enum Key: String {
private let defaults: UserDefaults
func string(for key: Key) -> String? {
func set(_ value: String?, for key: Key) {
func bool(for key: Key, fallback: Bool = false) -> Bool {
func set(_ value: Bool, for key: Key) {
func int(for key: Key, fallback: Int = 0) -> Int {
func set(_ value: Int, for key: Key) {
func double(for key: Key, fallback: Double = 0.0) -> Double {
func set(_ value: Double, for key: Key) {
func date(for key: Key) -> Date? {
func set(_ value: Date?, for key: Key) {
func stringArray(for key: Key) -> [String] {
func set(_ values: [String], for key: Key) {
func remove(_ key: Key) {
func removeAll() {
private func notify(_ key: Key) {
func customPalette() -> PaletteColors? {
func color(_ name: String) -> UIColor? {
func setCustomPalette(_ colors: PaletteColors) {
func recordLaunch() {
extension PrefsStore.Key {

## Flow/Core/Storage/SubscriptionStore.swift
struct Subscription {
let channelId: String
let name: String
let avatarUrl: String
let subscriberCount: Int
let subscribedAt: Date
let notificationsEnabled: Bool
final class SubscriptionStore {
private let database: FlowDB
func isSubscribed(_ channelId: String) -> Bool {
func subscription(for channelId: String) -> Subscription? {
func search(_ query: String) -> [Subscription] {
func subscribe(channelId: String, name: String, avatarUrl: String, subscriberCount: Int) {
func unsubscribe(channelId: String) {
func toggle(channelId: String, name: String, avatarUrl: String, subscriberCount: Int) -> Bool {
func setNotifications(enabled: Bool, channelId: String) {
func replaceAll(_ subscriptions: [Subscription]) {
func clear() {
private func reloadIndex() {

## Flow/Core/Theme/FlowPalettes.swift
enum ThemeVariant: String, CaseIterable {
struct PaletteSeed {
let primary: UIColor
let onPrimary: UIColor
let secondary: UIColor
let background: UIColor
let surface: UIColor
let onSurface: UIColor
let onSurfaceVariant: UIColor
let outline: UIColor
let error: UIColor
struct PaletteColors {
let primary: UIColor
let onPrimary: UIColor
let secondary: UIColor
let background: UIColor
let surface: UIColor
let surfaceContainerLow: UIColor
let surfaceContainer: UIColor
let surfaceContainerHigh: UIColor
let surfaceContainerHighest: UIColor
let outline: UIColor
let onSurface: UIColor
let onSurfaceVariant: UIColor
let error: UIColor
struct PalettePair {
let id: String
let light: PaletteSeed
let dark: PaletteSeed
func colors(for variant: ThemeVariant) -> PaletteColors {
enum AmoledLadder {
extension PaletteSeed {
func expanded(variant: ThemeVariant) -> PaletteColors {
enum FlowPalettes {
static func pair(for mode: ThemeMode) -> PalettePair {

## Flow/Core/Theme/FlowShapes.swift
enum FlowShapes {
static func pill(for height: CGFloat) -> CGFloat {
enum FlowSpacing {
enum FlowGridItemSize {

## Flow/Core/Theme/FlowTheme.swift
enum ThemeMode: String, CaseIterable {
static func fromStored(_ raw: String?) -> ThemeMode? {
static func storedDefaultVariant(_ raw: String?) -> ThemeVariant? {
func resolved(isSystemDark: Bool, systemLightMode: ThemeMode = .default, systemDarkMode: ThemeMode = .default) -> ThemeMode {
func isEffectivelyDark(isSystemDark: Bool, variant: ThemeVariant? = nil) -> Bool {
struct FlowColorScheme {
let primary: UIColor
let onPrimary: UIColor
let primaryContainer: UIColor
let onPrimaryContainer: UIColor
let inversePrimary: UIColor
let secondary: UIColor
let onSecondary: UIColor
let secondaryContainer: UIColor
let onSecondaryContainer: UIColor
let tertiary: UIColor
let onTertiary: UIColor
let tertiaryContainer: UIColor
let onTertiaryContainer: UIColor
let background: UIColor
let onBackground: UIColor
let surface: UIColor
let onSurface: UIColor
let surfaceVariant: UIColor
let onSurfaceVariant: UIColor
let surfaceTint: UIColor
let inverseSurface: UIColor
let inverseOnSurface: UIColor
let error: UIColor
let onError: UIColor
let errorContainer: UIColor
let onErrorContainer: UIColor
let outline: UIColor
let outlineVariant: UIColor
let scrim: UIColor
let surfaceBright: UIColor
let surfaceDim: UIColor
let surfaceContainerLowest: UIColor
let surfaceContainerLow: UIColor
let surfaceContainer: UIColor
let surfaceContainerHigh: UIColor
let surfaceContainerHighest: UIColor
let colors: PaletteColors
let isDark: Bool
let variant: ThemeVariant
extension PaletteColors {
func toColorScheme(variant: ThemeVariant) -> FlowColorScheme {
final class FlowTheme {
func refresh(notify: Bool = true) {
let colors: PaletteColors
func apply(mode newMode: ThemeMode) {
func apply(mode newMode: ThemeMode, variant newVariant: ThemeVariant) {
func applyCustom(_ colors: PaletteColors, variant newVariant: ThemeVariant) {
func updateSystemAppearance(isDark: Bool) {
func applyFont(_ choice: FlowFontChoice) {
func restore(from prefs: PrefsStore) {
func persist(to prefs: PrefsStore) {
enum FlowMotion {
static func animate(_ animations: @escaping () -> Void, completion: ((Bool) -> Void)? = nil) {
static func animateEmphasized(_ animations: @escaping () -> Void, completion: ((Bool) -> Void)? = nil) {

## Flow/Core/Theme/FlowTypography.swift
enum FlowFontChoice: String, CaseIterable {
enum FlowTypography {
static func family(for choice: FlowFontChoice) -> String {
static func font(size: CGFloat, weight: UIFont.Weight) -> UIFont {
static func scaled(size: CGFloat, weight: UIFont.Weight, textStyle: UIFont.TextStyle) -> UIFont {
static func lineHeight(for size: CGFloat) -> CGFloat {
static func letterSpacing(for size: CGFloat) -> CGFloat {
static func paragraphStyle(size: CGFloat, alignment: NSTextAlignment = .natural) -> NSParagraphStyle {
static func apply(_ font: UIFont, size: CGFloat, to label: UILabel, color: UIColor) {
extension UILabel {
static func flow(_ text: String, font: UIFont, color: UIColor, lines: Int = 1) -> UILabel {

## Flow/Net/InnerTube/BrowseParser.swift
enum BrowseParser {
static func homeFeed(from root: JSONNode) -> (sections: [VideoShelf], continuation: String?) {
var continuation: String?
static func homeChips(from root: JSONNode) -> [HomeChip] {
static func homeContinuation(from root: JSONNode) -> (sections: [VideoShelf], continuation: String?) {
private static func shelves(in node: JSONNode) -> [JSONNode] {
static func videoShelf(from node: JSONNode) -> VideoShelf? {
static func video(from node: JSONNode) -> Video? {
private static func videoRenderer(_ node: JSONNode) -> Video? {
private static func gridVideoRenderer(_ node: JSONNode) -> Video? {
private static func compactVideoRenderer(_ node: JSONNode) -> Video? {
private static func reelItemRenderer(_ node: JSONNode) -> Video? {
private static func playlistVideoRenderer(_ node: JSONNode) -> Video? {
private static func videoWithContextRenderer(_ node: JSONNode) -> Video? {
static func lockup(_ node: JSONNode) -> Video? {
static func metadataParts(_ metadata: JSONNode) -> [String] {
static func lockupByline(_ metadata: JSONNode) -> (id: String, name: String, avatarUrl: String)? {
static func channelPage(from root: JSONNode, requestedId: String) -> ChannelPage {
var videosContinuation: String?
var shortsContinuation: String?
var playlistsContinuation: String?
static func channelHeader(from root: JSONNode, requestedId: String) -> Channel {
static func channelTabs(from root: JSONNode) -> [ChannelTab] {
static func channelVideos(from root: JSONNode) -> (videos: [Video], continuation: String?) {
var continuation: String?
static func playlistPage(from root: JSONNode, requestedId: String) -> PlaylistPage {
var continuation: String?
static func playlistContinuation(from root: JSONNode) -> (videos: [Video], continuation: String?) {
var continuation: String?
static func playlist(from node: JSONNode) -> Playlist? {
static func suggestions(fromPayload payload: String) -> [String] {
private static func dedupe(_ videos: [Video]) -> [Video] {

## Flow/Net/InnerTube/InnerTubeClient.swift
enum FlowError: Error {
static func from(urlError: Error) -> FlowError {
struct InnerTubeLogEntry {
let date: Date
let method: String
let url: String
let status: Int?
let duration: TimeInterval
let byteCount: Int
let attempt: Int
let errorDescription: String?
final class InnerTubeClient {
var onVisitorDataChanged: ((String?) -> Void)?
var dataSyncId: String?
private let session: URLSession
func postMusic(
func postMainSite(
func postPlayer(
func getText(
func getJSON(
func postEmpty(
func fetchSuggestions(
func ensureVisitorData(completion: @escaping (String?) -> Void) {
private func requestVisitorData(completion: @escaping (String?) -> Void) {
private func requestVisitorDataFromScript(completion: @escaping (String?) -> Void) {
static func visitorDataFromScriptPayload(_ payload: String) -> String? {
func recentLog() -> [InnerTubeLogEntry] {
func clearLog() {
private func record(_ entry: InnerTubeLogEntry) {
private struct Payload {
let data: Data
let status: Int
private func post(
private func perform(
private func retry(
private func dropVisitorDataAndRetry(
static func decode(_ data: Data) -> Result<Any, FlowError> {
static func parseSuggestionsPayload(_ payload: String) -> [String] {
static func parseCookieString(_ cookie: String) -> [String: String] {
static func sha1Hex(_ input: String) -> String {
static func sha1(_ message: [UInt8]) -> [UInt8] {
var f: UInt32
var k: UInt32
static func base64(_ text: String) -> String {
static func playbackNonce() -> String {

## Flow/Net/InnerTube/InnerTubeContext.swift
struct YouTubeLocale: Equatable {
let gl: String
let hl: String
static func sanitizeCountry(_ value: String) -> String {
static func normalizeHostLanguage(_ languageTag: String) -> String {
let candidate: String
enum AttestationPlatform {
struct YouTubeClient {
let clientName: String
let clientVersion: String
let clientId: String
let userAgent: String
let osName: String?
let osVersion: String?
let deviceMake: String?
let deviceModel: String?
let androidSdkVersion: String?
let originalUrl: String?
let platform: String?
let utcOffsetMinutes: Int?
let buildId: String?
let cronetVersion: String?
let packageName: String?
let friendlyName: String?
let loginSupported: Bool
let loginRequired: Bool
let useSignatureTimestamp: Bool
let isEmbedded: Bool
let useWebPoTokens: Bool
let attestation: AttestationPlatform
let sendUserAgentInContext: Bool
func context(locale: YouTubeLocale, visitorData: String?, dataSyncId: String?) -> [String: Any] {

## Flow/Net/InnerTube/InnerTubeModels.swift
struct JSONNode {
let value: Any?
func first(_ keys: String...) -> JSONNode {
static func firstContinuation(in nodes: [JSONNode]) -> String? {
enum InnerTubeParse {
static func joinedRuns(_ node: JSONNode, separator: String = "") -> String? {
static func bylineSegments(_ node: JSONNode) -> [String] {
static func duration(from text: String?) -> Int? {
static func count(from text: String?) -> Int64? {
static func uploadDateText(_ node: JSONNode) -> String {
static func videoId(fromURLOrID raw: String) -> String? {
struct Video {
let id: String
var title: String
var channelName: String
var channelId: String
var thumbnailUrl: String
var duration: Int
var viewCount: Int64
var likeCount: Int64
var uploadDate: String
var timestamp: Date
var description: String
var channelThumbnailUrl: String
var tags: [String]
var category: String?
var isMusic: Bool
var isLive: Bool
var isShort: Bool
var isUpcoming: Bool
var membersOnlyText: String?
var commentCountText: String
var isVerifiedChannel: Bool
var badges: [String]
var snippet: String
func thumbnail(width: Int) -> String {
struct Channel {
let id: String
var name: String
var thumbnailUrl: String
var subscriberCount: Int64
var subscriberCountText: String
var description: String
var isSubscribed: Bool
var isMusic: Bool
var handle: String
var videoCount: Int
var isVerified: Bool
var bannerUrl: String
struct Playlist {
let id: String
var name: String
var thumbnailUrl: String
var videoCount: Int
var description: String
var videos: [Video]
var isLocal: Bool
var authorName: String
struct Comment {
let id: String
var author: String
var authorThumbnail: String
var authorChannelId: String
var text: String
var likeCount: Int
var likeCountText: String
var publishedTime: String
var replies: [Comment]
var replyCount: Int
var continuation: String?
var isPinned: Bool
var isHearted: Bool
var isVerified: Bool
var isCreator: Bool
enum VideoSearchFilter: String {
enum MusicSearchFilter: String {
enum MusicItem {
struct MusicArtist {
let name: String
let id: String?

## Flow/Net/InnerTube/MusicParser.swift
enum MusicParser {
static func item(from node: JSONNode) -> MusicItem? {
static func cardShelfItems(_ node: JSONNode) -> [MusicItem] {
static func carouselItems(_ node: JSONNode) -> [MusicItem] {
static func listItem(_ renderer: JSONNode) -> MusicItem? {
static func twoRowItem(_ renderer: JSONNode) -> MusicItem? {
private static func songItem(_ renderer: JSONNode, columns: [[JSONNode]]) -> MusicItem? {
private static func albumItem(_ renderer: JSONNode, columns: [[JSONNode]]) -> MusicItem? {
private static func playlistItem(_ renderer: JSONNode, columns: [[JSONNode]]) -> MusicItem? {
private static func artistItem(_ renderer: JSONNode, columns: [[JSONNode]], isProfile: Bool) -> MusicItem? {
static func musicHome(from root: JSONNode) -> MusicHome {
static func homeChips(from root: JSONNode) -> [HomeChip] {
static func homeContinuation(from root: JSONNode) -> MusicHome {
private static func homeSection(_ node: JSONNode) -> HomeSection? {
static func albumPage(from root: JSONNode, browseId: String) -> AlbumPage {
private static func albumHeader(from root: JSONNode) -> JSONNode {
private static func albumPlaylistId(from root: JSONNode) -> String {
private static func albumSongs(from root: JSONNode, album: AlbumItem) -> [SongItem] {
private static func otherVersions(from root: JSONNode, album: AlbumItem) -> [AlbumItem] {
static func artistPage(from root: JSONNode, browseId: String) -> ArtistPage {
private static func artistSection(_ content: JSONNode) -> ArtistSection? {
static func musicPlaylistPage(from root: JSONNode, playlistId: String) -> MusicPlaylistPage {
var continuation: String?
static func musicPlaylistContinuation(from root: JSONNode) -> (songs: [SongItem], continuation: String?) {
var continuation: String?
static func moodsAndGenres(from root: JSONNode) -> [MoodAndGenreGroup] {
static func lyricsBrowseId(fromNext root: JSONNode) -> String? {
static func lyrics(from root: JSONNode) -> Lyrics? {
static func musicPageType(_ endpoint: JSONNode) -> String {
static func flexColumns(_ renderer: JSONNode) -> [[JSONNode]] {
private static func firstText(_ columns: [[JSONNode]], index: Int) -> String? {
static func separatorGroups(_ runs: [JSONNode]) -> [[JSONNode]] {
static func oddElements(_ runs: [JSONNode]) -> [JSONNode] {
private static func artist(from run: JSONNode) -> MusicArtist {
private static func thumbnailUrl(_ node: JSONNode) -> String {
private static func isExplicit(_ node: JSONNode) -> Bool {
private static func musicVideoType(_ renderer: JSONNode) -> String? {
static func menuPlaylistEndpoint(_ renderer: JSONNode, iconType: String) -> String? {
private static func subscribeChannelId(_ menu: JSONNode) -> String? {

## Flow/Net/InnerTube/NextParser.swift
enum NextParser {
static func watchMetadata(from root: JSONNode, videoId: String) -> (video: Video, description: VideoDescription, chapters: [Chapter]) {
private static func likeCountFrom(_ node: JSONNode) -> Int64 {
static func chapters(from root: JSONNode) -> [Chapter] {
let end: TimeInterval?
static func related(from root: JSONNode) -> [Video] {
static func commentsContinuation(from root: JSONNode) -> String? {
static func comments(from root: JSONNode) -> CommentsPage {
var continuation: String?
static func commentReplies(from root: JSONNode) -> CommentsPage {
var continuation: String?
private static func continuationItems(from root: JSONNode) -> [JSONNode] {
private static func commentMutations(from root: JSONNode) -> [String: JSONNode] {
private static func commentThread(_ thread: JSONNode, mutations: [String: JSONNode]) -> Comment? {
var comment: Comment?
private static func modernComment(_ node: JSONNode, mutations: [String: JSONNode]) -> Comment? {
private static func legacyComment(_ node: JSONNode) -> Comment? {
static func transcript(from root: JSONNode) -> [TranscriptLine] {

## Flow/Net/InnerTube/PlayerParser.swift
enum PlayerParser {
struct Result {
let status: String
let reason: String?
let videoId: String
let title: String
let author: String
let channelId: String
let lengthSeconds: Int
let viewCount: Int64
let shortDescription: String
let keywords: [String]
let isLive: Bool
let isLiveContent: Bool
let hlsManifestUrl: String?
let dashManifestUrl: String?
let formats: [StreamFormat]
let adaptiveFormats: [StreamFormat]
let captions: [CaptionTrack]
let musicVideoType: String?
let category: String?
let publishDate: String?
let thumbnailUrl: String
let scheduledStartTime: String?
static func parse(_ root: JSONNode) -> Result {
static func format(from node: JSONNode) -> StreamFormat? {
static func unavailableReason(for result: Result) -> String {
static func bestAudio(in result: Result) -> StreamFormat? {
static func bestProgressive(in result: Result) -> StreamFormat? {
static func videoTrack(in result: Result, maximumHeight: Int) -> StreamFormat? {
static func availableHeights(in result: Result) -> [Int] {

## Flow/Net/InnerTube/SearchParser.swift
enum SearchParser {
static func videoResults(from root: JSONNode) -> VideoSearchResults {
var continuation: String?
var estimated: Int64?
static func videoContinuation(from root: JSONNode) -> VideoSearchResults {
var continuation: String?
private static func collectSearchItem(
private static func channel(from node: JSONNode) -> Channel? {
private static func channelFromLockup(_ node: JSONNode) -> Channel? {
private static func searchChips(from node: JSONNode) -> [SearchChip] {
static func musicResults(from root: JSONNode) -> MusicSearchResults {
var continuation: String?
static func musicContinuation(from root: JSONNode) -> MusicSearchResults {
var continuation: String?
private static func dedupeVideos(_ videos: [Video]) -> [Video] {

## Flow/Net/InnerTube/YouTubeAPI.swift
final class YouTubeAPI {
let client: InnerTubeClient
func home(completion: @escaping (Result<VideoHomeFeed, FlowError>) -> Void) {
func homeContinuation(_ token: String, completion: @escaping (Result<VideoHomeFeed, FlowError>) -> Void) {
func musicHome(completion: @escaping (Result<MusicHome, FlowError>) -> Void) {
func musicHomeChips(completion: @escaping (Result<[HomeChip], FlowError>) -> Void) {
func musicHomeContinuation(_ token: String, completion: @escaping (Result<MusicHome, FlowError>) -> Void) {
func search(
func searchContinuation(_ token: String, completion: @escaping (Result<VideoSearchResults, FlowError>) -> Void) {
func musicSearch(
func musicSearchContinuation(_ token: String, completion: @escaping (Result<MusicSearchResults, FlowError>) -> Void) {
func suggestions(query: String, completion: @escaping (Result<[String], FlowError>) -> Void) {
func watch(videoId: String, completion: @escaping (Result<WatchPage, FlowError>) -> Void) {
var playerResult: Result<PlayerParser.Result, FlowError>?
var nextResult: Result<JSONNode, FlowError>?
let nextRoot: JSONNode
func player(videoId: String, completion: @escaping (Result<PlayerParser.Result, FlowError>) -> Void) {
func related(videoId: String, completion: @escaping (Result<[Video], FlowError>) -> Void) {
func comments(
func commentReplies(continuation: String, completion: @escaping (Result<CommentsPage, FlowError>) -> Void) {
private func commentsContinuation(_ token: String, completion: @escaping (Result<CommentsPage, FlowError>) -> Void) {
func chapters(videoId: String, completion: @escaping (Result<[Chapter], FlowError>) -> Void) {
func channel(id: String, completion: @escaping (Result<ChannelPage, FlowError>) -> Void) {
func channelTab(
func playlist(id: String, completion: @escaping (Result<PlaylistPage, FlowError>) -> Void) {
func playlistContinuation(_ token: String, completion: @escaping (Result<(videos: [Video], continuation: String?), FlowError>) -> Void) {
func artist(id: String, completion: @escaping (Result<ArtistPage, FlowError>) -> Void) {
func album(id: String, completion: @escaping (Result<AlbumPage, FlowError>) -> Void) {
func musicPlaylist(id: String, completion: @escaping (Result<MusicPlaylistPage, FlowError>) -> Void) {
func musicPlaylistContinuation(_ token: String, completion: @escaping (Result<(songs: [SongItem], continuation: String?), FlowError>) -> Void) {
func moodsAndGenres(completion: @escaping (Result<[MoodAndGenreGroup], FlowError>) -> Void) {
func lyrics(videoId: String, completion: @escaping (Result<Lyrics?, FlowError>) -> Void) {
func transcript(videoId: String, completion: @escaping (Result<[TranscriptLine], FlowError>) -> Void) {
private func requestPlayer(
private func context(client: YouTubeClient = .web) -> [String: Any] {
private func postMusic(
private func postMainSite(
private func browseMusic(
private func browseMainSite(
private func nextWatch(videoId: String, completion: @escaping (Result<JSONNode, FlowError>) -> Void) {
private func fallbackHome(error: FlowError, completion: @escaping (Result<VideoHomeFeed, FlowError>) -> Void) {
private static func decode(
static func watchPage(player: PlayerParser.Result, next: JSONNode, videoId: String) -> WatchPage {
static func video(from item: MusicItem) -> Video {

## Flow/Net/Services/DeArrowService.swift
struct DeArrowTitle {
let title: String
let votes: Int
let locked: Bool
let original: Bool
struct DeArrowThumbnail {
let timestamp: Double?
let votes: Int
let locked: Bool
let original: Bool
struct DeArrowContent {
let titles: [DeArrowTitle]
let thumbnails: [DeArrowThumbnail]
let randomTime: Double?
let videoDuration: Double?
struct DeArrowResult {
let title: String?
let thumbnailUrl: String?
final class DeArrowService {
private struct Entry {
let content: DeArrowContent?
let fetchedAt: Date
private let client: InnerTubeClient
func cached(videoId: String) -> DeArrowContent? {
func branding(videoId: String, completion: @escaping (DeArrowContent?) -> Void) {
private func fetch(videoId: String, completion: @escaping (DeArrowContent?) -> Void) {
private func store(videoId: String, content: DeArrowContent?) {
func clearCache() {
static func resolve(
var title: String?
var frameTime: Double?
var thumbnail: String?
private static func randomFrameTime(content: DeArrowContent, fallbackDurationSeconds: Int) -> Double? {
let duration: Double
static func frameURL(videoId: String, timeSeconds: Double) -> String {
static func stripCaseMarkers(_ title: String) -> String {
static func parse(_ body: String) -> DeArrowContent? {

## Flow/Net/Services/LyricsService.swift
final class LyricsService {
private struct Entry {
let lyrics: Lyrics
let fetchedAt: Date
private let client: InnerTubeClient
private let api: YouTubeAPI
func lyrics(
func cached(for videoId: String) -> Lyrics? {
func clearCache() {
private func store(videoId: String, lyrics: Lyrics) {
private func fetchSimpMusic(videoId: String, duration: Int, completion: @escaping (Lyrics?) -> Void) {
private func fetchLrcLib(title: String, artist: String, duration: Int, completion: @escaping (Lyrics?) -> Void) {
private func searchLrcLib(title: String, artist: String, duration: Int, completion: @escaping (Lyrics?) -> Void) {
private func fetchYouTube(videoId: String, completion: @escaping (Result<Lyrics?, FlowError>) -> Void) {
static func parseSimpMusic(_ body: String, duration: Int) -> Lyrics? {
let candidates: [[String: Any]]
private static func bestCandidate(_ candidates: [[String: Any]], duration: Int) -> [String: Any] {
static func parseLrcLibObject(_ body: String) -> Lyrics? {
static func parseLrcLibSearch(_ body: String, duration: Int) -> Lyrics? {
private static func lyricsFromLrcLibEntry(_ entry: [String: Any]) -> Lyrics? {
static func plainLines(_ text: String) -> [LyricLine] {
static func parseLRC(_ text: String) -> [LyricLine] {
private static func timestamps(in line: String) -> [TimeInterval] {
private static func parseStamp(_ text: String) -> TimeInterval? {
private static func stripTimestamps(from line: String) -> String {
static func parseRichSync(_ text: String, duration: Int) -> [LyricLine]? {
private static func lineText(words: [[String: Any]], fallback: String?) -> String {
private static func normaliseTime(_ value: Double, duration: Int) -> TimeInterval {

## Flow/Net/Services/ReturnYouTubeDislikeService.swift
struct DislikeCounts {
let videoId: String
let likes: Int64?
let dislikes: Int64?
let rating: Double?
let viewCount: Int64?
let isDeleted: Bool
final class ReturnYouTubeDislikeService {
private struct Entry {
let counts: DislikeCounts
let fetchedAt: Date
private let client: InnerTubeClient
func counts(for videoId: String, completion: @escaping (DislikeCounts?) -> Void) {
func cached(for videoId: String) -> DislikeCounts? {
func clearCache() {
private func fetch(videoId: String, completion: @escaping (DislikeCounts?) -> Void) {
static func parse(_ body: String) -> DislikeCounts? {

## Flow/Net/Services/SponsorBlockService.swift
enum SponsorBlockCategory: String, CaseIterable {
static func displayName(for category: String) -> String? {
static func defaultColor(for category: String) -> Int64 {
static func defaultAction(for category: String) -> SponsorBlockAction {
enum SponsorBlockAction: String, CaseIterable {
static func fromString(_ name: String) -> SponsorBlockAction {
struct SponsorBlockSegment {
let category: String
let startTime: Float
let endTime: Float
let uuid: String
let actionType: String
let votes: Int
let isFullVideo: Bool
func contains(_ time: Float) -> Bool {
final class SponsorBlockService {
private struct CacheEntry {
let segments: [SponsorBlockSegment]
let fetchedAt: Date
private let client: InnerTubeClient
func segments(
func cachedSegments(for videoId: String) -> [SponsorBlockSegment]? {
func store(_ segments: [SponsorBlockSegment], for videoId: String) {
func clearCache() {
private func fetch(videoId: String, completion: @escaping (Result<[SponsorBlockSegment], FlowError>) -> Void) {
func submitSegment(
static func parseSegments(_ body: String) -> [SponsorBlockSegment] {
static func serialize(_ segments: [SponsorBlockSegment]) -> String {
private static func jsonArray(_ values: [String]) -> String {

## Flow/Net/Services/WatchPageService.swift
struct WatchPageModel {
let page: WatchPage
let title: String
let thumbnailUrl: String
let sponsorSegments: [SponsorBlockSegment]
let deArrow: DeArrowResult?
let dislikeCounts: DislikeCounts?
final class WatchPageService {
let api: YouTubeAPI
let sponsorBlock: SponsorBlockService
let deArrow: DeArrowService
let dislikes: ReturnYouTubeDislikeService
func load(videoId: String, completion: @escaping (Result<WatchPageModel, FlowError>) -> Void) {
func enrich(
var branding: DeArrowResult?
var counts: DislikeCounts?
private func model(

## Flow/Playback/AudioEngine.swift
enum EqFilterType: String, CaseIterable {
struct EqBand: Equatable {
var frequency: Double
var gain: Double
var q: Double
var type: EqFilterType
var enabled: Bool
struct EqPreset: Equatable {
let id: String
let name: String
let gains: [Double]
let preamp: Double
final class AudioEngine {
private var storedBands: [EqBand]
private var storedEnabled: Bool
private var storedPreamp: Double
private var storedPresetId: String
var onChange: (() -> Void)?
func setEnabled(_ enabled: Bool) {
func setBands(_ bands: [EqBand], presetId: String? = nil) {
func setBand(at index: Int, band: EqBand) {
func setGain(_ gain: Double, at index: Int) {
func setPreamp(_ preamp: Double) {
func apply(_ preset: EqPreset) {
func reset() {
func audioMix(for item: AVPlayerItem) -> AVAudioMix? {
private func makeTap() -> MTAudioProcessingTap? {
var tap: MTAudioProcessingTap?
private final class TapContext {
let engine: AudioEngine
fileprivate func makeFilters(sampleRate: Double, channelCount: Int) -> [[BiquadFilter]] {
fileprivate func refreshFilters(_ filters: inout [[BiquadFilter]], appliedRevision: inout Int) {
private static func cascade(
private func rebuildLocked() {
private func persist() {
private func restore() {
private func notify() {
static func defaultBands() -> [EqBand] {
private static func normalised(_ bands: [EqBand]) -> [EqBand] {
struct BiquadFilter {
enum Kind {
private let b0: Double
private let b1: Double
private let b2: Double
private let a1: Double
private let a2: Double
private static func coefficients(

## Flow/Playback/ChapterBarView.swift
final class ChapterBarView: UIView {
struct ChapterSegment {
let title: String
let start: TimeInterval
let end: TimeInterval
var onChapterSelected: ((TimeInterval) -> Void)?
var onSegmentSelected: ((SponsorBlockSegment) -> Void)?
private func commonInit() {
func setChapters(_ chapters: [ChapterSegment], duration: TimeInterval) {
func setSegments(_ segments: [SponsorBlockSegment]) {
func setPosition(_ position: TimeInterval) {
func applyTheme() {
private func recomputeChapterColors() {
private func recomputeSegmentColors() {
override func draw(_ rect: CGRect) {
private func updateAccessibility() {
override func accessibilityIncrement() {
override func accessibilityDecrement() {
final class ChapterListView: UIView, UITableViewDataSource, UITableViewDelegate {
var onSelect: ((TimeInterval) -> Void)?
private func commonInit() {
func setChapters(_ chapters: [ChapterBarView.ChapterSegment], currentTime: TimeInterval) {
func applyTheme() {
func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
private final class ChapterCell: UITableViewCell {
private func commonInit() {
func configure(index: Int, title: String, time: TimeInterval, isCurrent: Bool) {
func applyTheme() {

## Flow/Playback/MiniPlayerView.swift
final class MiniPlayerView: UIView {
var onExpand: (() -> Void)?
var onDismiss: (() -> Void)?
var onPlayPause: (() -> Void)?
var onSkip: ((Bool) -> Void)?
private var progressWidth: NSLayoutConstraint?
private var service: PlaybackService?
private var currentItem: PlaybackQueueItem?
private var marqueeTimer: Timer?
private func commonInit() {
func bind(to service: PlaybackService) {
private func render(_ snapshot: PlaybackSnapshot) {
private func setTitle(_ title: String) {
private func startMarqueeIfNeeded() {
private func stopMarquee() {
private func resetPosition() {
private func dismiss() {
func applyTheme() {
final class MiniArtworkRing: UIView {
private func commonInit() {
override func layoutSubviews() {
func setImageURL(_ urlString: String) {
func setProgress(_ value: CGFloat) {
func applyTheme() {

## Flow/Playback/PiPController.swift
final class PiPController: NSObject, AVPictureInPictureControllerDelegate {
var onActiveChanged: ((Bool) -> Void)?
var onRestoreRequested: (() -> Void)?
var onExpandRequested: (() -> Void)?
func attach(to layer: AVPlayerLayer) {
func detach() {
func start() -> Bool {
func stop() {
func toggle() -> Bool {
func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
func pictureInPictureController(
func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
func pictureInPictureController(
final class PlayerLayerView: UIView {
private func commonInit() {
func setVideoGravity(_ gravity: AVLayerVideoGravity) {

## Flow/Playback/PlaybackService.swift
struct PlaybackSnapshot: Equatable {
var item: PlaybackQueueItem?
var isPlaying: Bool
var isBuffering: Bool
var duration: TimeInterval
var position: TimeInterval
var rate: Float
var repeatMode: RepeatMode
var shuffleEnabled: Bool
var queueTitle: String?
var queueCount: Int
var queueIndex: Int
var error: String?
final class PlaybackService: NSObject {
var onItemChanged: ((PlaybackQueueItem?) -> Void)?
var onQueueFinished: (() -> Void)?
var onSegmentSkipped: ((SponsorBlockSegment) -> Void)?
private let api: YouTubeAPI
private let watchService: WatchPageService
private let history: HistoryStore
private let prefs: PrefsStore
private var timeObserver: Any?
private var itemStatusObservation: NSKeyValueObservation?
private var itemKeepUpObservation: NSKeyValueObservation?
private var playerRateObservation: NSKeyValueObservation?
private var endObserver: NSObjectProtocol?
private var interruptionObserver: NSObjectProtocol?
private var routeChangeObserver: NSObjectProtocol?
private var foregroundObserver: NSObjectProtocol?
private var pendingSeek: TimeInterval?
private var artworkTask: URLSessionDataTask?
private func configurePlayer() {
private func configureQueue() {
private func configureAudioSession() {
private func activateSession() {
private func observeSystemEvents() {
func load(videoId: String, autoplay: Bool = true, completion: ((Result<PlaybackQueueItem, FlowError>) -> Void)? = nil) {
func play(
func play(video: Video, autoplay: Bool = true) {
func play(song: SongItem, autoplay: Bool = true) {
func enqueue(_ item: PlaybackQueueItem) {
func playNext(_ item: PlaybackQueueItem) {
func playQueueItem(at index: Int) {
func removeQueueItem(at index: Int) {
func moveQueueItem(from source: Int, to destination: Int) {
private func loadFresh(
private func begin(item: PlaybackQueueItem, autoplay: Bool, resume: Bool) {
private func buildItem(
private func install(localItem url: URL, item: PlaybackQueueItem, autoplay: Bool, resume: Bool) {
private func install(playerItem: AVPlayerItem, item: PlaybackQueueItem, autoplay: Bool, resume: Bool) {
private func observeItem(_ item: AVPlayerItem) {
private func detachItemObservers() {
private func attachEndObserver(for item: AVPlayerItem) {
func play() {
func pause() {
func togglePlayPause() {
func stop() {
func seek(to seconds: TimeInterval) {
func skip(by seconds: TimeInterval) {
func playNext() {
func playPrevious() {
func setPlaybackSpeed(_ speed: Double) {
private func playbackSpeed() -> Float {
func setShuffle(_ enabled: Bool) {
func setRepeatMode(_ mode: RepeatMode) {
func cycleRepeatMode() {
func setQuality(_ quality: String) {
func refreshEqualizer() {
func startSleepTimer(minutes: Int, closesApp: Bool = false) {
func startSleepTimerAtEndOfItem(closesApp: Bool = false) {
func cancelSleepTimer() {
private func handleSleepTimerExpiry(_ expiry: SleepTimer.Expiry) {
private func handleTimeUpdate(_ seconds: TimeInterval) {
private func applySponsorBlock(at time: TimeInterval) {
private func startPosition(for item: PlaybackQueueItem) -> TimeInterval {
private func saveHistory(force: Bool) {
private func handleItemEnded() {
private func handleInterruption(_ notification: Notification) {
private func handleRouteChange(_ notification: Notification) {
private func updateNowPlaying() {

## Flow/Playback/PlayerControlsView.swift
final class PlayerControlsView: UIView {
enum Action {
var onAction: ((Action) -> Void)?
var onRetry: (() -> Void)?
private func commonInit() {
private func buildTopBar() {
private func buildCentreRow() {
private func buildBottomBar() {
private func buildOverlays() {
private func configureTextButton(_ button: UIButton, title: String, accessibility: String) {
private static func makeThumb() -> UIImage {
func render(snapshot: PlaybackSnapshot, isFullscreen: Bool, hasChapters: Bool, hasSponsorSegments: Bool) {
func setQualityLabel(_ label: String) {
func setChapters(_ chapters: [ChapterBarView.ChapterSegment], segments: [SponsorBlockSegment], duration: TimeInterval) {
func setSleepTimerActive(_ active: Bool) {
func setVisible(_ visible: Bool, animated: Bool) {
func applyTheme() {
func setCompact(_ compact: Bool) {
final class GradientScrim: UIView {
enum Direction {
private let direction: Direction
override func layoutSubviews() {

## Flow/Playback/PlayerGestureController.swift
final class PlayerGestureController: NSObject, UIGestureRecognizerDelegate {
enum Feedback {
private enum Axis {
var onFeedback: ((Feedback) -> Void)?
var onSingleTap: (() -> Void)?
var onSeekCommitted: ((TimeInterval) -> Void)?
var onSeekBegan: (() -> Void)?
var onDoubleTapSeek: ((TimeInterval) -> Void)?
func attach(to view: UIView, service: PlaybackService) {
private func updateGestureStates() {
let delta: TimeInterval
private func clearFeedback(after delay: TimeInterval) {
func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
func gestureRecognizer(
static func systemVolume() -> Float {
static func setSystemVolume(_ value: Float) {
func restoreBrightness() {
final class MPVolumeViewHolder {
func setVolume(_ value: Float) {
private static func findSlider(in view: UIView) -> UISlider? {

## Flow/Playback/PlayerItemFactory.swift
enum PlaybackHeaders {
static func media(referer: String = "https://www.youtube.com/") -> [String: String] {
final class HeaderInjectingAssetLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate {
private let headers: [String: String]
static func interceptableURL(_ url: URL) -> URL {
static func originalURL(_ url: URL) -> URL {
static func asset(for url: URL, headers: [String: String]) -> AVURLAsset {
func resourceLoader(
func resourceLoader(
func urlSession(
func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
struct PlaybackQuality: Equatable {
let value: String
let label: String
let height: Int
enum PlayerItemFactory {
struct Options {
var audioLanguage: String?
var localFileURL: URL?
static func qualities(for page: WatchPage) -> [PlaybackQuality] {
static func requestedHeight(from quality: String) -> Int {
static func makeItem(
private static func compose(
var failure: FlowError?
private static func loadError(for asset: AVAsset, keys: [String]) -> FlowError? {
static func bestProgressive(in page: WatchPage, height: Int) -> StreamFormat? {
static func bestVideo(in page: WatchPage, height: Int) -> StreamFormat? {
static func bestAudio(in page: WatchPage, language: String?) -> StreamFormat? {
private static func applyBufferPolicy(to item: AVPlayerItem, options: Options) {
private static func applyQualityCap(to item: AVPlayerItem, height: Int, page: WatchPage) {

## Flow/Playback/Queue.swift
struct PlaybackQueueItem: Equatable {
let videoId: String
var title: String
var channelName: String
var channelId: String
var thumbnailUrl: String
var duration: TimeInterval
var isMusic: Bool
var albumName: String?
var localFileURL: URL?
enum RepeatMode: String {
static func fromStored(_ raw: String?) -> RepeatMode {
final class Queue {
var onChange: (() -> Void)?
func item(at index: Int) -> PlaybackQueueItem? {
func index(of videoId: String) -> Int? {
func nextIndex(manual: Bool) -> Int? {
func previousIndex() -> Int? {
func setItems(
func clear() {
func jump(to index: Int) -> PlaybackQueueItem? {
func advance(manual: Bool = false) -> PlaybackQueueItem? {
func rewind() -> PlaybackQueueItem? {
func append(_ item: PlaybackQueueItem) -> Int {
func append(contentsOf newItems: [PlaybackQueueItem]) {
func insertNext(_ item: PlaybackQueueItem) -> Int {
func remove(at index: Int) -> PlaybackQueueItem? {
func move(from source: Int, to destination: Int) {
func setShuffle(_ enabled: Bool) {
func setRepeatMode(_ mode: RepeatMode) {
func cycleRepeatMode() {
func restoreModes(repeatMode: RepeatMode, shuffle: Bool) {
private func notify() {

## Flow/Playback/QueueSheetViewController.swift
final class QueueSheetViewController: UIViewController {
private let service: PlaybackService
var onDismiss: (() -> Void)?
override func viewDidLoad() {
private func buildHeader() {
private func buildTable() {
private func buildEmptyState() {
private func reload() {
private func applyTheme() {
func present(from presenter: UIViewController? = nil) {
extension QueueSheetViewController: UITableViewDataSource, UITableViewDelegate {
func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
func tableView(
func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
func tableView(
func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool {
final class QueueRowCell: UITableViewCell {
private func commonInit() {
func configure(item: PlaybackQueueItem, isCurrent: Bool, position: Int) {
override func layoutSubviews() {

## Flow/Playback/SleepTimer.swift
final class SleepTimer {
enum Expiry {
enum Mode: Equatable {
var onExpire: ((Expiry) -> Void)?
var onTick: ((TimeInterval?) -> Void)?
private var source: DispatchSourceTimer?
func start(minutes: Int, closesApp: Bool = false) {
func startEndOfMedia(closesApp: Bool = false) {
func mediaDidEnd() {
func cancel() {
private func cancel(notify: Bool) {
private func fire(_ expiry: Expiry) {
private func startTicking() {

## Flow/Playback/SubtitleParser.swift
struct SubtitleCue: Equatable {
let start: TimeInterval
let end: TimeInterval
let lines: [String]
func contains(_ time: TimeInterval, tolerance: TimeInterval = 0.05) -> Bool {
struct SubtitleTrackFile {
let cues: [SubtitleCue]
let format: SubtitleParser.Format
func cue(at time: TimeInterval) -> SubtitleCue? {
enum SubtitleParser {
enum Format: String {
static func parse(_ text: String) -> SubtitleTrackFile? {
static func parseSRT(_ text: String) -> [SubtitleCue] {
static func parseVTT(_ text: String) -> [SubtitleCue] {
var timingIndex: Int?
static func parseTimingLine(_ line: String) -> (start: TimeInterval, end: TimeInterval)? {
static func parseTimestamp(_ text: String) -> TimeInterval? {
static func cleanLines(_ lines: [String]) -> [String] {
private static func stripAngleTags(_ text: String) -> String {
private static func stripBraceTags(_ text: String) -> String {
private static func decodeEntities(_ text: String) -> String {
static func collapseRollingCaptions(_ cues: [SubtitleCue]) -> [SubtitleCue] {

## Flow/Playback/SubtitleRenderer.swift
struct SubtitleStyle {
var fontScale: CGFloat
var textColor: UIColor
var backgroundOpacity: CGFloat
final class SubtitleTrack {
let languageCode: String
let name: String
let isAutomatic: Bool
let file: SubtitleTrackFile
let url: String
func cue(at time: TimeInterval) -> SubtitleCue? {
final class SubtitleLoader {
private let client: InnerTubeClient
func load(
var parsed: Result<SubtitleTrackFile, FlowError>
func cached(track: CaptionTrack) -> SubtitleTrackFile? {
func clearCache() {
static func captionURL(from baseUrl: String) -> String? {
final class SubtitleRenderer: UIView {
private func commonInit() {
func setTrack(_ track: SubtitleTrack?) {
func update(time: TimeInterval) {
func clearVisibleCue() {
private func showText(_ text: String, animated: Bool) {
private func rebuildLabels(for text: String) {
func applyStyle() {
func reloadStyleFromPreferences() {

## Flow/Playback/VideoPlayerViewController.swift
final class VideoPlayerViewController: UIViewController {
private let service: PlaybackService
var onBack: (() -> Void)?
var onOpenDetails: (() -> Void)?
private var hideWorkItem: DispatchWorkItem?
private var subtitleTrack: SubtitleTrack?
private var selectedCaption: CaptionTrack?
override func viewDidLoad() {
override func viewWillAppear(_ animated: Bool) {
override func viewWillDisappear(_ animated: Bool) {
override func viewDidAppear(_ animated: Bool) {
private func buildViews() {
private func wireControls() {
private func wireGestures() {
private func wirePiP() {
private func observeService() {
private func observeTheme() {
private func applyTheme() {
private func render(_ snapshot: PlaybackSnapshot) {
private func visibleSegments() -> [SponsorBlockSegment] {
private func updateChapters() {
let fallback: TimeInterval
private func updateChaptersIfNeeded() {
private func applyQualityLabel() {
func showControls(autoHide: Bool) {
func toggleControls() {
private func scheduleHide() {
private func handle(_ action: PlayerControlsView.Action) {
func toggleFullscreen() {
private func requestOrientation(_ orientation: UIInterfaceOrientation) {
func togglePiP() {
private var timeObserverToken: Any?
private func attachTimeObserver() {
private func detachTimeObserver() {
private func applySubtitleStyle() {
func loadSubtitle(_ track: CaptionTrack) {
func clearSubtitles() {
private func show(feedback: PlayerGestureController.Feedback) {
private func presentSettingsSheet() {
private func presentQualitySheet() {
private func presentSpeedSheet() {
private func presentSubtitleSheet() {
private func presentChaptersSheet() {
private func presentQueueSheet() {
private func presentSleepTimerSheet() {
private func presentSponsorBlockSheet() {
final class PlayerHUD: UIView {
enum Kind {
private var fillWidth: NSLayoutConstraint?
private var hideWorkItem: DispatchWorkItem?
private func commonInit() {
override func layoutSubviews() {
func show(kind: Kind, value: CGFloat) {
func showSeek(target: TimeInterval, delta: TimeInterval) {
func hide() {
final class DoubleTapSeekIndicator: UIView {
private func commonInit() {
func show(delta: TimeInterval) {
final class PlayerSettingsSheet: UIView {
enum Row {
var onSelect: ((Row) -> Void)?
private func build() {
private func makeRow(_ row: (Row, String, String?, FlowIcon)) -> UIControl {
final class ChoiceSheetContent: UIView, UITableViewDataSource, UITableViewDelegate {
struct Option {
let title: String
let subtitle: String?
let isSelected: Bool
private var options: [Option]
var onSelect: ((Int) -> Void)?
func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
private func nearestSheet() -> FlowSheet? {
private final class ChoiceCell: UITableViewCell {
private func commonInit() {
func configure(title: String, subtitle: String?, isSelected: Bool) {
final class SponsorBlockSheetContent: UIView {
private var onToggleAutoSkip: ((Bool) -> Void)?
final class SleepTimerSheetController: UIView {

## Flow/App/AppDelegate.swift
final class AppDelegate: UIResponder, UIApplicationDelegate {
var window: UIWindow?
private var launchViewController: LaunchViewController?
private var themeToken: ObservationToken?
func application(
private func presentLaunchScreen(over shell: RootTabBarController) {
private func applyAppearanceProxies() {
private func observeTheme() {
func application(
private func handleIncoming(_ url: URL) -> Bool {
func applicationDidEnterBackground(_ application: UIApplication) {
func applicationWillResignActive(_ application: UIApplication) {
func applicationWillTerminate(_ application: UIApplication) {
func applicationDidReceiveMemoryWarning(_ application: UIApplication) {

## Flow/App/FlowApp.swift
final class FlowApp {
let youtubeAPI: YouTubeAPI
let historyStore: HistoryStore
let subscriptionStore: SubscriptionStore
let playlistStore: PlaylistStore
let downloadStore: DownloadStore
let noteStore: NoteStore
let prefs: PrefsStore
let imageLoader: ImageLoader
let theme: FlowTheme
let playback: PlaybackService
func bootstrap() {
private func restoreNetworkIdentity() {
func persistPlaybackPosition() {
func handleMemoryWarning() {

## Flow/App/RootTabBarController.swift
final class RootTabBarController: UITabBarController, UITabBarControllerDelegate {
private enum Tab: Int, CaseIterable {
private var miniPlayerBottom: NSLayoutConstraint?
override func viewDidLoad() {
private func buildTabs() {
private func makeRootController(for tab: Tab) -> UIViewController {
let controller: UIViewController
private func makeTabBarItem(for tab: Tab) -> UITabBarItem {
private func installMiniPlayer() {
private func refreshMiniPlayer(animated: Bool) {
private func applyMiniPlayerInset() {
private func observePlayback() {
func applyTheme() {
private func restoreSelectedTab() {
private func persistSelectedTab(_ tab: Tab) {
func index(of route: Route) -> Int? {
func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
func tabBarController(
extension Array {

## Flow/App/Router.swift
enum Route: Hashable {
enum DeepLink {
static func parse(_ url: URL) -> Route? {
private static func queryValues(_ components: URLComponents?) -> [String: String] {
final class Router {
func register(_ route: Route, builder: @escaping Builder) {
func canOpen(_ route: Route) -> Bool {
private func isTabRoute(_ route: Route) -> Bool {
func openWatch(videoId: String) {
func openChannel(id: String) {
func openPlaylist(id: String) {
func openSearch(query: String) {
func openMusic(artistId: String) {
func openSettings() {
func open(_ route: Route) {
func makeViewController(for route: Route) -> UIViewController? {
func selectTab(_ route: Route) {
func push(_ viewController: UIViewController, from presenter: UIViewController? = nil, animated: Bool = true) {
func present(_ viewController: UIViewController, from presenter: UIViewController? = nil, animated: Bool = true) {
private func existingController(for route: Route) -> UIViewController? {
private func pop(to controller: UIViewController) {
static func topViewController() -> UIViewController? {
static func visibleController(in controller: UIViewController) -> UIViewController {
static func rootViewController() -> UIViewController? {
static func rootTabBarController() -> RootTabBarController? {
extension UIViewController {