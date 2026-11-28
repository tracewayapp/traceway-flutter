/// When session replay may show the app's images: the `replay.images`
/// setting, and the `TracewayOptions.replayImages` ceiling. The effective
/// policy is the lower of the two, in the order `off < wifi < always`.
///
/// Under [always], and under [wifi] on an unmetered network, the wireframe
/// inlines a small picture of every image's decoded pixels (network, asset,
/// memory and file images; at most 384 px, JPEG, or PNG up to 192 px when the
/// image has transparency). Under [wifi] on a metered or unknown network,
/// network images stay URL references and no pixels are uploaded; [off] draws
/// placeholders. Anything under a mask is never encoded, and video recordings
/// are not affected. Android and iOS follow the same rules.
enum TracewayImagePolicy {
  /// Every image is a placeholder.
  off,

  /// Images on an unmetered network (Wi-Fi, Ethernet); the default
  /// setting. On a metered or unknown network Flutter keeps network images
  /// as URL references and uploads no pixels.
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
