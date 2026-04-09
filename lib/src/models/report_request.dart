import 'collection_frame.dart';

class ReportRequest {
  final List<CollectionFrame> collectionFrames;
  final String appVersion;
  final String serverName;

  const ReportRequest({
    required this.collectionFrames,
    this.appVersion = '',
    this.serverName = '',
  });

  Map<String, dynamic> toJson() => {
    'collectionFrames':
        collectionFrames.map((e) => e.toJson()).toList(),
    'appVersion': appVersion,
    'serverName': serverName,
  };
}
