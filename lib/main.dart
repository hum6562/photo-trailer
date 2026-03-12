import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart' as pm;
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'dart:ui' as ui;
import 'dart:math';

// 엔진 파일 경로가 정확한지 확인하세요!
import 'services/trip_logic.dart'; 

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: PhotoMapScreen()
  ));
}

class PhotoMapScreen extends StatefulWidget {
  const PhotoMapScreen({super.key});
  @override
  State<PhotoMapScreen> createState() => _PhotoMapScreenState();
}

class _PhotoMapScreenState extends State<PhotoMapScreen> {
  GoogleMapController? _mapController;
  final ScrollController _panoramaController = ScrollController();

  Set<Marker> _markers = {};
  Set<Marker> _allTripMarkers = {}; 
  Set<Polyline> _polylines = {};
  List<Trip> _trips = [];
  int? _selectedTripIndex;

  bool _isLoading = false;
  String _statusText = "준비 중...";

  @override
  void initState() {
    super.initState();
    _panoramaController.addListener(_onPanoramaScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _buildTravelPath());
  }

  void _onPanoramaScroll() {
    if (_selectedTripIndex == null || _isLoading) return;
    final trip = _trips[_selectedTripIndex!];
    final allPhotos = trip.places.expand((p) => p.photos).toList();
    if (allPhotos.isEmpty) return;

    int currentIndex = (_panoramaController.offset / 88.0).round().clamp(0, allPhotos.length - 1);
    final loc = allPhotos[currentIndex].location;
    if (loc != null) {
      _mapController?.animateCamera(CameraUpdate.newLatLng(loc));
    }
  }

  Future<void> _buildTravelPath() async {
    setState(() { _isLoading = true; _statusText = "사진 분석 중..."; });

    final pm.PermissionState ps = await pm.PhotoManager.requestPermissionExtend();
    if (!ps.isAuth && !ps.hasAccess) return;

    final albums = await pm.PhotoManager.getAssetPathList(type: pm.RequestType.image, onlyAll: true);
    if (albums.isEmpty) return;

    final assets = await albums[0].getAssetListRange(start: 0, end: 2000);

    List<RawPhoto> rawPhotos = [];
    for (var asset in assets) {
      final loc = await asset.latlngAsync();
      rawPhotos.add(RawPhoto(
        id: asset.id,
        location: (loc != null && loc.latitude != 0) ? LatLng(loc.latitude, loc.longitude) : null,
        time: asset.createDateTime,
        width: asset.width.toDouble(),
        height: asset.height.toDouble(),
        isFavorite: asset.isFavorite,
        originalAsset: asset,
      ));
    }

    final analyzedTrips = await compute(_runAnalysis, rawPhotos);

    Set<Marker> overviewMarkers = {};
    for (int i = 0; i < analyzedTrips.length; i++) {
      final trip = analyzedTrips[i];
      if (trip.places.isEmpty) continue;
      
      final firstPlace = trip.places.first;
      final bestPhoto = firstPlace.representative.originalAsset;
      
      if (bestPhoto != null) {
        overviewMarkers.add(Marker(
          markerId: MarkerId("ov_$i"),
          position: firstPlace.centroid,
          icon: await _getPhotoMarker(bestPhoto),
          onTap: () => _onTripSelected(i),
        ));
      }
    }

    setState(() {
      _trips = analyzedTrips;
      _allTripMarkers = overviewMarkers;
      _markers = overviewMarkers;
      _isLoading = false;
      _statusText = "여정 ${analyzedTrips.length}개 발견";
    });
  }

  static List<Trip> _runAnalysis(List<RawPhoto> photos) => UltimateTravelEngine().segment(photos);

  Future<void> _onTripSelected(int index) async {
    setState(() { _selectedTripIndex = index; _isLoading = true; });
    final trip = _trips[index];
    _polylines = { Polyline(polylineId: PolylineId("p$index"), points: trip.path, color: Colors.orange, width: 5) };
    
    Set<Marker> detailMarkers = {};
    for (int i = 0; i < trip.places.length; i++) {
      final asset = trip.places[i].representative.originalAsset;
      if (asset != null) {
        detailMarkers.add(Marker(
          markerId: MarkerId("pl$i"),
          position: trip.places[i].centroid,
          icon: await _getPhotoMarker(asset),
        ));
      }
    }

    setState(() { _markers = detailMarkers; _isLoading = false; });
    if (trip.path.isNotEmpty) {
      _mapController?.animateCamera(CameraUpdate.newLatLngBounds(_getBounds(trip.path), 70));
    }
  }

  LatLngBounds _getBounds(List<LatLng> points) {
    if (points.isEmpty) return LatLngBounds(southwest: const LatLng(0,0), northeast: const LatLng(0,0));
    double minLat = points[0].latitude, maxLat = points[0].latitude;
    double minLng = points[0].longitude, maxLng = points[0].longitude;
    for (var p in points) {
      minLat = min(minLat, p.latitude); maxLat = max(maxLat, p.latitude);
      minLng = min(minLng, p.longitude); maxLng = max(maxLng, p.longitude);
    }
    return LatLngBounds(southwest: LatLng(minLat, minLng), northeast: LatLng(maxLat, maxLng));
  }

  Future<BitmapDescriptor> _getPhotoMarker(pm.AssetEntity entity) async {
    final data = await entity.thumbnailDataWithSize(const pm.ThumbnailSize(100, 100));
    if (data == null) return BitmapDescriptor.defaultMarker;
    final codec = await ui.instantiateImageCodec(data);
    final fi = await codec.getNextFrame();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const size = 50.0;
    canvas.drawCircle(const Offset(size/2, size/2), size/2, Paint()..color = Colors.white);
    canvas.clipPath(Path()..addOval(const Rect.fromLTWH(2, 2, size-4, size-4)));
    canvas.drawImageRect(fi.image, Rect.fromLTWH(0, 0, fi.image.width.toDouble(), fi.image.height.toDouble()), const Rect.fromLTWH(0, 0, size, size), Paint());
    final img = await recorder.endRecording().toImage(size.toInt(), size.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) return BitmapDescriptor.defaultMarker;
    return BitmapDescriptor.bytes(bytes.buffer.asUint8List());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("사진소"), backgroundColor: Colors.orangeAccent),
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: const CameraPosition(target: LatLng(36.5, 127.5), zoom: 6.5),
            onMapCreated: (c) => _mapController = c,
            markers: _markers,
            polylines: _polylines,
            onTap: (_) { setState(() { _selectedTripIndex = null; _markers = _allTripMarkers; _polylines = {}; }); },
          ),
          Positioned(top: 20, left: 20, right: 20, child: _buildStatusCard()),
          if (_isLoading) const Center(child: CircularProgressIndicator(color: Colors.orangeAccent)),
          if (_selectedTripIndex != null) Positioned(bottom: 30, left: 0, right: 0, child: _buildTripListView()),
        ],
      ),
    );
  }

  Widget _buildStatusCard() => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(color: Colors.white.withAlpha(230), borderRadius: BorderRadius.circular(30), boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 10)]),
    child: Text(_statusText, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold)),
  );

  Widget _buildTripListView() {
    final trip = _trips[_selectedTripIndex!];
    final allPhotos = trip.places.expand((p) => p.photos).toList();
    return SizedBox(
      height: 140,
      child: ListView.builder(
        controller: _panoramaController,
        scrollDirection: Axis.horizontal,
        itemCount: allPhotos.length,
        itemBuilder: (context, idx) {
          final asset = allPhotos[idx].originalAsset;
          if (asset == null) return const SizedBox.shrink();
          return Container(
            width: 100, 
            margin: const EdgeInsets.all(8), 
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10), 
              child: AssetEntityImage(asset, fit: BoxFit.cover)
            )
          );
        },
      ),
    );
  }
}