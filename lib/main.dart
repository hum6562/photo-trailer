import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart' as pm;
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'dart:ui' as ui;
import 'dart:math';

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
  
  // 🔥 로딩 상태 표시용 변수
  int _processedCount = 0;
  int _totalCount = 0;

  @override
  void initState() {
    super.initState();
    _panoramaController.addListener(_onPanoramaScroll);
    // 처음엔 최근 3개월만 분석
    WidgetsBinding.instance.addPostFrameCallback((_) => _buildTravelPath(loadAll: false));
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

  // 🔥 파라미터로 전체 불러오기 여부를 받음
  Future<void> _buildTravelPath({required bool loadAll}) async {
    setState(() { 
      _isLoading = true; 
      _statusText = loadAll ? "모든 사진 불러오는 중..." : "최근 3개월 사진 불러오는 중..."; 
      _processedCount = 0;
      _totalCount = 0;
    });

    final pm.PermissionState ps = await pm.PhotoManager.requestPermissionExtend();
    if (!ps.isAuth && !ps.hasAccess) {
      setState(() => _isLoading = false);
      return;
    }

    final albums = await pm.PhotoManager.getAssetPathList(type: pm.RequestType.image, onlyAll: true);
    if (albums.isEmpty) return;

    // 전체를 부를 땐 앨범 전체 개수, 아니면 넉넉히 최대치로 잡고 날짜로 자름
    int fetchCount = loadAll ? await albums[0].assetCountAsync : 5000;
    final assets = await albums[0].getAssetListRange(start: 0, end: fetchCount);
    
    DateTime threeMonthsAgo = DateTime.now().subtract(const Duration(days: 90));

    List<RawPhoto> rawPhotos = [];
    setState(() { _totalCount = assets.length; });

    for (int i = 0; i < assets.length; i++) {
      var asset = assets[i];
      
      // 전체 불러오기가 아닐 때, 3개월 이전 사진이 나오면 스톱 (사진이 최신순이라는 전제)
      if (!loadAll && asset.createDateTime.isBefore(threeMonthsAgo)) {
        setState(() { _totalCount = i; }); // 실제 처리할 총 장수 수정
        break;
      }

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

      // 🔥 UI 렉을 줄이기 위해 20장마다 상태 업데이트
      if (i % 20 == 0) {
        setState(() { _processedCount = i + 1; _statusText = "사진 위치 읽는 중..."; });
      }
    }

    setState(() { _statusText = "사진 정리 중... (잠시만 기다려주세요)"; });
    final analyzedTrips = await compute(_runAnalysis, rawPhotos);

    Set<Marker> overviewMarkers = {};
    for (int i = 0; i < analyzedTrips.length; i++) {
      final trip = analyzedTrips[i];
      if (trip.places.isEmpty) continue;
      
      final firstPlace = trip.places.first;
      final bestPhoto = firstPlace.representative.originalAsset;
      
      if (bestPhoto != null) {
        // 🔥 여행은 오렌지색, 일상은 하얀색 테두리
        Color borderColor = trip.isTrip ? Colors.orangeAccent : Colors.white;
        
        overviewMarkers.add(Marker(
          markerId: MarkerId("ov_$i"),
          position: firstPlace.centroid,
          icon: await _getPhotoMarker(bestPhoto, borderColor),
          onTap: () => _onTripSelected(i),
        ));
      }
    }

    setState(() {
      _trips = analyzedTrips;
      _allTripMarkers = overviewMarkers;
      _markers = overviewMarkers;
      _isLoading = false;
      
      int tripCount = _trips.where((t) => t.isTrip).length;
      int dailyCount = _trips.length - tripCount;
      _statusText = "완료! (여행 $tripCount개, 일상 $dailyCount개)";
    });
  }

  static List<Trip> _runAnalysis(List<RawPhoto> photos) => UltimateTravelEngine().segment(photos);

  Future<void> _onTripSelected(int index) async {
    setState(() { _selectedTripIndex = index; _isLoading = true; });
    final trip = _trips[index];
    
    // 🔥 여행일 때만 주황색 선 그리기 (일상은 선 없음)
    if (trip.isTrip && trip.path.length > 1) {
      _polylines = { Polyline(polylineId: PolylineId("p$index"), points: trip.path, color: Colors.orange, width: 5) };
    } else {
      _polylines = {};
    }
    
    Set<Marker> detailMarkers = {};
    for (int i = 0; i < trip.places.length; i++) {
      final asset = trip.places[i].representative.originalAsset;
      if (asset != null) {
        detailMarkers.add(Marker(
          markerId: MarkerId("pl$i"),
          position: trip.places[i].centroid,
          icon: await _getPhotoMarker(asset, Colors.white), // 세부 마커는 기본 흰색
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

  // 🔥 테두리 색상(borderColor)을 받도록 수정
  Future<BitmapDescriptor> _getPhotoMarker(pm.AssetEntity entity, Color borderColor) async {
    final data = await entity.thumbnailDataWithSize(const pm.ThumbnailSize(100, 100));
    if (data == null) return BitmapDescriptor.defaultMarker;
    final codec = await ui.instantiateImageCodec(data);
    final fi = await codec.getNextFrame();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const size = 60.0; // 테두리를 잘 보이게 약간 키움
    
    // 테두리 그리기
    canvas.drawCircle(const Offset(size/2, size/2), size/2, Paint()..color = borderColor);
    // 사진이 들어갈 둥근 영역 클리핑 (테두리 두께 4px)
    canvas.clipPath(Path()..addOval(const Rect.fromLTWH(4, 4, size-8, size-8)));
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
          
          // 🔥 장수 기반 로딩 바 추가
          if (_isLoading) _buildLoadingOverlay(),
          
          if (_selectedTripIndex != null) Positioned(bottom: 30, left: 0, right: 0, child: _buildTripListView()),
        ],
      ),
      // 🔥 모든 사진 분석하는 플로팅 버튼 추가
      floatingActionButton: (_isLoading || _selectedTripIndex != null) ? null : FloatingActionButton.extended(
        onPressed: () => _buildTravelPath(loadAll: true),
        label: const Text("모든 사진 분석하기"),
        icon: const Icon(Icons.photo_library),
        backgroundColor: Colors.orangeAccent,
      ),
    );
  }

  Widget _buildStatusCard() => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(color: Colors.white.withAlpha(230), borderRadius: BorderRadius.circular(30), boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 10)]),
    child: Text(_statusText, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold)),
  );

  // 🔥 로딩 바 UI
  Widget _buildLoadingOverlay() {
    return Positioned(
      bottom: 50, left: 40, right: 40,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
        decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(15)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text("데이터를 처리 중입니다...", style: const TextStyle(color: Colors.white, fontSize: 14)),
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: _totalCount == 0 ? null : (_processedCount / _totalCount),
              backgroundColor: Colors.grey[700],
              color: Colors.orangeAccent,
            ),
            const SizedBox(height: 10),
            Text(
              "$_processedCount / $_totalCount 장", 
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)
            ),
          ],
        ),
      ),
    );
  }

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
