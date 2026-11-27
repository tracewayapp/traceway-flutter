/// When session replay may show the app's images: the `replay.images`
/// setting, and the `TracewayOptions.replayImages` ceiling. The effective
/// policy is the lower of the two, in the order `off < wifi < always`.
///
/// Flutter's wireframe never uploads image pixels: an image loaded from the
/// network is shown by its URL, which the browser that plays the replay
/// fetches. So [wifi] and [always] both keep those URLs, and [off] draws a
/// placeholder instead. Images from memory, files and assets are always
/// placeholders, and video recordings are not affected. The Android and iOS
/// SDKs, which upload pictures, upload them only on an unmetered network
/// under [wifi].
enum TracewayImagePolicy {
  /// Every image is a placeholder.
  off,

  /// Images on an unmetered network (Wi-Fi, Ethernet); the default
  /// setting. On Flutter, the same as [always].
  wifi,

  /// Images on any network; the default ceiling.
  always;

  /// The policy named [value] (`off`, `wifi`, `always`), or null.
  static TracewayImagePolicy? parse(Object? value) => switch (value) {
        'off' => off,
        'wifi' => wifi,
        'always' => always,
        _ => null,
      };

  /// The lower of this policy and [other].
  TracewayImagePolicy lower(TracewayImagePolicy other) =>
      other.index < index ? other : this;
}
