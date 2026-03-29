import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart' as pm;
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'dart:ui' as ui;
import 'dart:math';
import 'dart:convert'; 
import 'package:shared_preferences/shared_preferences.dart'; 

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
  
  PageController? _pageController;
  ScrollController? _verticalScrollController;
  
  bool _isRightListScrolling = false; 
  int _lastSyncedIndex = -1;

  Set<Marker> _markers = {};
  final List<Marker> _rawOverviewMarkers = []; 
  
  Set<Polyline> _polylines = {};
  List<Trip> _trips = [];
  int? _selectedTripIndex;

  bool _isGlobalLoading = false;
  bool _isTripLoading = false;
  bool _showStatusCard = true; 
  
  // 전체 분석 완료 여부를 추적하는 변수 추가함
  bool _isAllLoaded = false; 

  String _statusText = "준비 중...";
  int _processedCount = 0;
  int _totalCount = 0;

  final Map<String, BitmapDescriptor> _photoIconCache = {};
  final Map<int, BitmapDescriptor> _arrowIconCache = {};
  final List<Marker> _currentTripPlaceMarkers = [];
  final List<Marker> _currentTripArrowMarkers = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _buildTravelPath(loadAll: false));
  }

  @override
  void dispose() {
    _pageController?.dispose();
    _verticalScrollController?.dispose();
    super.dispose();
  }

  void _onPageScroll() {
    if (_selectedTripIndex == null || _isGlobalLoading || _isTripLoading || _pageController == null || !_pageController!.hasClients) return;
    
    final trip = _trips[_selectedTripIndex!];
    final allPhotos = trip.places.expand((p) => p.photos).toList();
    if (allPhotos.isEmpty) return;

    double page = _pageController!.page ?? 0;
    
    if (_verticalScrollController != null && _verticalScrollController!.hasClients && !_isRightListScrolling) {
      _verticalScrollController!.jumpTo(page * 60.0);
    }

    int currentIndex = page.round().clamp(0, allPhotos.length - 1);
    
    if (_lastSyncedIndex != currentIndex) {
      _lastSyncedIndex = currentIndex;
      final loc = allPhotos[currentIndex].location;
      if (loc != null) {
        _mapController?.animateCamera(CameraUpdate.newLatLng(loc));
      }
    }
  }

  Future<void> _buildTravelPath({required bool loadAll}) async {
    setState(() { 
      _isGlobalLoading = true; 
      _showStatusCard = true;
      _statusText = loadAll ? "모든 사진 불러오는 중..." : "최근 3개월 사진 불러오는 중..."; 
      _processedCount = 0;
      _totalCount = 0;
    });

    final pm.PermissionState ps = await pm.PhotoManager.requestPermissionExtend();
    if (!ps.isAuth && !ps.hasAccess) {
      setState(() => _isGlobalLoading = false);
      return;
    }

    final albums = await pm.PhotoManager.getAssetPathList(type: pm.RequestType.image, onlyAll: true);
    if (albums.isEmpty) return;

    int fetchCount = loadAll ? await albums[0].assetCountAsync : 5000;
    final assets = await albums[0].getAssetListRange(start: 0, end: fetchCount);
    DateTime threeMonthsAgo = DateTime.now().subtract(const Duration(days: 90));

    setState(() { _statusText = "로컬 캐시 데이터 확인 중..."; });
    final prefs = await SharedPreferences.getInstance();
    final String? cachedString = prefs.getString('photo_location_cache');
    Map<String, dynamic> locationCache = cachedString != null ? jsonDecode(cachedString) : {};
    bool isCacheUpdated = false;

    List<RawPhoto> rawPhotos = [];
    setState(() { _totalCount = assets.length; });

    int chunkSize = 250;
    for (int i = 0; i < assets.length; i += chunkSize) {
      if (!loadAll && assets[i].createDateTime.isBefore(threeMonthsAgo)) {
        setState(() { _totalCount = i; }); 
        break;
      }

      int end = (i + chunkSize < assets.length) ? i + chunkSize : assets.length;
      var chunk = assets.sublist(i, end);
      
      List<Future<pm.LatLng?>> fetchTasks = [];
      for (var asset in chunk) {
        if (!locationCache.containsKey(asset.id)) {
          fetchTasks.add(asset.latlngAsync());
        } else {
          fetchTasks.add(Future.value(null));
        }
      }

      var fetchedLocations = await Future.wait(fetchTasks);

      for (int j = 0; j < chunk.length; j++) {
        var asset = chunk[j];
        LatLng? parsedLoc;

        if (locationCache.containsKey(asset.id)) {
          var cLoc = locationCache[asset.id];
          if (cLoc != null) {
            parsedLoc = LatLng(cLoc[0], cLoc[1]);
          }
        } else {
          var loc = fetchedLocations[j];
          if (loc != null && loc.latitude != 0) {
            parsedLoc = LatLng(loc.latitude, loc.longitude);
            locationCache[asset.id] = [loc.latitude, loc.longitude];
          } else {
            locationCache[asset.id] = null;
          }
          isCacheUpdated = true;
        }

        rawPhotos.add(RawPhoto(
          id: asset.id,
          location: parsedLoc,
          time: asset.createDateTime,
          width: asset.width.toDouble(),
          height: asset.height.toDouble(),
          isFavorite: asset.isFavorite,
          originalAsset: asset,
        ));
      }

      setState(() { 
        _processedCount = end; 
        _statusText = "사진 쾌속 로딩 중... ($_processedCount / $_totalCount)"; 
      });
    }

    if (isCacheUpdated) {
      setState(() { _statusText = "위치 캐시 데이터 저장 중..."; });
      await prefs.setString('photo_location_cache', jsonEncode(locationCache));
    }

    setState(() { _statusText = "사진 정리 중... (잠시만 기다려주세요)"; });
    final analyzedTrips = await compute(_runAnalysis, rawPhotos);

    analyzedTrips.sort((a, b) {
      if (a.isTrip && !b.isTrip) return -1; 
      if (!a.isTrip && b.isTrip) return 1;
      return b.totalPhotoCount.compareTo(a.totalPhotoCount); 
    });

    _rawOverviewMarkers.clear();

    for (int i = 0; i < analyzedTrips.length; i++) {
      final trip = analyzedTrips[i];
      if (trip.places.isEmpty) continue;
      
      final mainPlace = trip.mainPlace;
      final bestPhoto = mainPlace.representative.originalAsset;
      
      if (bestPhoto != null) {
        Color borderColor = trip.isTrip ? const Color(0xFF1A237E) : const Color(0xFF00897B);
        
        _rawOverviewMarkers.add(Marker(
          markerId: MarkerId("ov_$i"),
          position: mainPlace.centroid,
          icon: await _getPhotoMarker(bestPhoto, borderColor, count: trip.totalPhotoCount),
          onTap: () => _onTripSelected(i), 
        ));
      }
    }

    setState(() {
      _trips = analyzedTrips;
      _isGlobalLoading = false;
      
      // 전체 로딩이 실행된 경우 플래그를 true로 변경하여 버튼을 완전히 숨김
      if (loadAll) {
        _isAllLoaded = true;
      }
      
      int tripCount = _trips.where((t) => t.isTrip).length;
      int dailyCount = _trips.length - tripCount;
      _statusText = "완료! (여행 $tripCount개, 일상 $dailyCount개)";
    });

    double initialZoom = _mapController != null ? await _mapController!.getZoomLevel() : 6.5;
    _filterOverviewMarkersByZoom(initialZoom);

    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showStatusCard = false);
    });
  }

  static List<Trip> _runAnalysis(List<RawPhoto> photos) => UltimateTravelEngine().segment(photos);

  double _calculateBearing(LatLng start, LatLng end) {
    double lat1 = start.latitude * pi / 180;
    double lon1 = start.longitude * pi / 180;
    double lat2 = end.latitude * pi / 180;
    double lon2 = end.longitude * pi / 180;
    double dLon = lon2 - lon1;
    double y = sin(dLon) * cos(lat2);
    double x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon);
    double bearing = atan2(y, x) * 180 / pi;
    return (bearing + 360) % 360;
  }

  double _calcDistanceMeters(LatLng p1, LatLng p2) {
    var R = 6371e3; 
    var phi1 = p1.latitude * pi / 180;
    var phi2 = p2.latitude * pi / 180;
    var dPhi = (p2.latitude - p1.latitude) * pi / 180;
    var dLambda = (p2.longitude - p1.longitude) * pi / 180;
    var a = sin(dPhi / 2) * sin(dPhi / 2) + cos(phi1) * cos(phi2) * sin(dLambda / 2) * sin(dLambda / 2);
    var c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return R * c;
  }

  Future<BitmapDescriptor> _getArrowMarker(double opacity) async {
    int cacheKey = (opacity * 10).round();
    if (_arrowIconCache.containsKey(cacheKey)) return _arrowIconCache[cacheKey]!;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const size = 40.0;
    
    final paint = Paint()..color = Colors.white.withValues(alpha: opacity)..style = PaintingStyle.stroke..strokeWidth = 4.0..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round;
    final path = Path()..moveTo(10, 22)..lineTo(20, 8)..lineTo(30, 22)..moveTo(10, 32)..lineTo(20, 18)..lineTo(30, 32);
      
    canvas.drawPath(path.shift(const Offset(0, 2)), Paint()..color = Colors.black45.withValues(alpha: opacity * 0.5)..style = PaintingStyle.stroke..strokeWidth = 4.0..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round);
    canvas.drawPath(path, paint..color = Colors.orangeAccent.withValues(alpha: opacity));

    final img = await recorder.endRecording().toImage(size.toInt(), size.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    final marker = BitmapDescriptor.bytes(bytes!.buffer.asUint8List());
    _arrowIconCache[cacheKey] = marker;
    return marker;
  }

  Future<void> _onTripSelected(int index) async {
    setState(() { _selectedTripIndex = index; _isTripLoading = true; _markers = {}; _polylines = {}; });
    
    final trip = _trips[index];
    final allPhotos = trip.places.expand((p) => p.photos).toList();
    
    int startIndex = 0;
    final mainAssetId = trip.mainPlace.representative.originalAsset?.id;
    if (mainAssetId != null) {
      startIndex = allPhotos.indexWhere((p) => p.originalAsset?.id == mainAssetId);
      if (startIndex == -1) startIndex = 0;
    }

    _lastSyncedIndex = startIndex; 

    _pageController?.dispose();
    _pageController = PageController(viewportFraction: 0.28, initialPage: startIndex);
    _pageController!.addListener(_onPageScroll);

    _verticalScrollController?.dispose();
    _verticalScrollController = ScrollController(initialScrollOffset: startIndex * 60.0);
    
    _currentTripPlaceMarkers.clear();
    _currentTripArrowMarkers.clear();
    
    for (int i = 0; i < trip.places.length; i++) {
      final asset = trip.places[i].representative.originalAsset;
      if (asset != null) {
        _currentTripPlaceMarkers.add(Marker(
          markerId: MarkerId("pl$i"),
          position: trip.places[i].centroid,
          icon: await _getPhotoMarker(asset, Colors.white), 
          zIndexInt: 2, 
          onTap: () {
            int idx = allPhotos.indexWhere((p) => p.originalAsset?.id == asset.id);
            if (idx != -1) {
              _pageController?.animateToPage(idx, duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
            }
          }
        ));
      }
    }

    if (trip.isTrip && trip.path.length > 1) {
      _polylines = { 
        Polyline(polylineId: PolylineId("p$index"), points: trip.path, color: Colors.orange.withValues(alpha: 0.4), width: 5) 
      };
      
      final engine = UltimateTravelEngine();
      for (int i = 0; i < trip.path.length - 1; i++) {
        LatLng p1 = trip.path[i];
        LatLng p2 = trip.path[i+1];
        if (engine.getDistance(p1, p2) < 2.0) continue; 
        
        double bearing = _calculateBearing(p1, p2);
        LatLng midPoint = LatLng((p1.latitude + p2.latitude) / 2, (p1.longitude + p2.longitude) / 2);
        double progress = i / (trip.path.length - 1);
        double arrowOpacity = 1.0 - (progress * 0.5); 
        
        _currentTripArrowMarkers.add(Marker(
          markerId: MarkerId("arrow_$i"),
          position: midPoint,
          icon: await _getArrowMarker(arrowOpacity.clamp(0.2, 1.0)),
          rotation: bearing, 
          anchor: const Offset(0.5, 0.5),
          zIndexInt: 1, 
        ));
      }
    }

    setState(() { _isTripLoading = false; });
    
    if (_mapController != null) {
      double zoom = await _mapController!.getZoomLevel();
      _filterMarkersByZoom(zoom);
    }
    
    if (trip.isTrip && trip.path.isNotEmpty) {
      _mapController?.animateCamera(CameraUpdate.newLatLngBounds(_getBounds(trip.path), 70));
    } else if (!trip.isTrip) {
      _mapController?.animateCamera(CameraUpdate.newLatLng(trip.mainPlace.centroid));
    }
  }

  void _filterOverviewMarkersByZoom(double zoom) {
    Set<Marker> visibleMarkers = {};
    double metersPerPixel = 156543.03 * 0.803 / pow(2, zoom);
    double thresholdMeters = 50.0 * metersPerPixel; 

    for (var m in _rawOverviewMarkers) {
      bool overlaps = false;
      for (var v in visibleMarkers) {
        if (_calcDistanceMeters(m.position, v.position) < thresholdMeters) {
          overlaps = true;
          break;
        }
      }
      if (!overlaps) visibleMarkers.add(m);
    }
    
    setState(() { _markers = visibleMarkers; });
  }

  void _filterMarkersByZoom(double zoom) {
    if (_selectedTripIndex == null) return;
    Set<Marker> visibleMarkers = {};
    
    double metersPerPixel = 156543.03 * 0.803 / pow(2, zoom);
    double thresholdMeters = 40.0 * metersPerPixel; 

    for (var m in _currentTripPlaceMarkers) {
      bool overlaps = false;
      for (var v in visibleMarkers) {
        if (_calcDistanceMeters(m.position, v.position) < thresholdMeters) {
          overlaps = true;
          break;
        }
      }
      if (!overlaps) visibleMarkers.add(m);
    }
    
    List<Marker> visibleArrows = [];
    for (var a in _currentTripArrowMarkers) {
      bool overlaps = false;
      for (var v in visibleArrows) {
        if (_calcDistanceMeters(a.position, v.position) < (thresholdMeters * 0.8)) { 
          overlaps = true;
          break;
        }
      }
      if (!overlaps) visibleArrows.add(a);
    }
    visibleMarkers.addAll(visibleArrows);
    
    setState(() { _markers = visibleMarkers; });
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

  Future<BitmapDescriptor> _getPhotoMarker(pm.AssetEntity entity, Color borderColor, {int? count}) async {
    final String cacheKey = "${entity.id}_${count ?? 0}";
    if (_photoIconCache.containsKey(cacheKey)) return _photoIconCache[cacheKey]!;

    final data = await entity.thumbnailDataWithSize(const pm.ThumbnailSize(100, 100));
    if (data == null) return BitmapDescriptor.defaultMarker;
    final codec = await ui.instantiateImageCodec(data);
    final fi = await codec.getNextFrame();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    
    const double canvasSize = 100.0; 
    const double photoSize = 65.0; 
    const double dxOffset = 10.0;
    const double dyOffset = 25.0; 
    
    canvas.drawCircle(const Offset(photoSize/2 + dxOffset, photoSize/2 + dyOffset), photoSize/2, Paint()..color = borderColor);
    canvas.clipPath(Path()..addOval(const Rect.fromLTWH(dxOffset + 2, dyOffset + 2, photoSize - 4, photoSize - 4)));
    canvas.drawImageRect(fi.image, Rect.fromLTWH(0, 0, fi.image.width.toDouble(), fi.image.height.toDouble()), const Rect.fromLTWH(dxOffset, dyOffset, photoSize, photoSize), Paint());
    
    if (count != null && count > 0) {
      String text = count > 99 ? "99+" : count.toString();
      final textPainter = TextPainter(
        text: TextSpan(text: text, style: TextStyle(color: Colors.white.withValues(alpha: 0.95), fontSize: 12, fontWeight: FontWeight.bold)), 
        textDirection: TextDirection.ltr
      )..layout();
      
      double badgeRadius = 14.0;
      Offset badgeCenter = const Offset(70.0, 23.0); 
      
      canvas.drawCircle(badgeCenter, badgeRadius, Paint()..color = Colors.black.withValues(alpha: 0.6));
      textPainter.paint(canvas, Offset(badgeCenter.dx - textPainter.width/2, badgeCenter.dy - textPainter.height/2));
    }

    final img = await recorder.endRecording().toImage(canvasSize.toInt(), canvasSize.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    final marker = BitmapDescriptor.bytes(bytes!.buffer.asUint8List());
    _photoIconCache[cacheKey] = marker;
    return marker;
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
            onCameraIdle: () async {
              if (_mapController != null) {
                double zoom = await _mapController!.getZoomLevel();
                if (_selectedTripIndex != null) {
                  _filterMarkersByZoom(zoom);
                } else {
                  _filterOverviewMarkersByZoom(zoom);
                }
              }
            },
            onTap: (_) async { 
              setState(() { _selectedTripIndex = null; _polylines = {}; }); 
              if (_mapController != null) {
                double zoom = await _mapController!.getZoomLevel();
                _filterOverviewMarkersByZoom(zoom);
              }
            },
          ),
          
          Positioned(
            top: 20, left: 20, right: 20, 
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _showStatusCard ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 600),
                child: _buildStatusCard(),
              ),
            ),
          ),
          
          if (_isTripLoading) 
            Positioned(top: 0, left: 0, right: 0, child: LinearProgressIndicator(backgroundColor: Colors.transparent, color: Colors.orangeAccent, minHeight: 5)),
          if (_isGlobalLoading) _buildLoadingOverlay(),
          
          if (_selectedTripIndex != null) ...[
            Positioned(bottom: 20, left: 0, right: 0, child: _buildTripFilmStrip()),
            Positioned(right: 15, top: 90, width: 60, child: _buildVerticalFastScroller()),
          ],
        ],
      ),
      // 🔥 _isAllLoaded 조건이 추가되어 버튼이 영구적으로 사라집니다.
      floatingActionButton: (_isGlobalLoading || _selectedTripIndex != null || _isAllLoaded) ? null : FloatingActionButton.extended(
        onPressed: () => _buildTravelPath(loadAll: true),
        label: const Text("모든 사진 분석하기"),
        icon: const Icon(Icons.photo_library),
        backgroundColor: Colors.orangeAccent,
      ),
    );
  }

  Widget _buildStatusCard() => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(30), boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 10)]),
    child: Text(_statusText, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold)),
  );

  Widget _buildLoadingOverlay() {
    return Positioned(
      bottom: 50, left: 40, right: 40,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
        decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(15)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("데이터를 처리 중입니다...", style: TextStyle(color: Colors.white, fontSize: 14)),
            const SizedBox(height: 10),
            LinearProgressIndicator(value: _totalCount == 0 ? null : (_processedCount / _totalCount), backgroundColor: Colors.grey[700], color: Colors.orangeAccent),
            const SizedBox(height: 10),
            Text("$_processedCount / $_totalCount 장", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
          ],
        ),
      ),
    );
  }

  Widget _buildVerticalFastScroller() {
    final trip = _trips[_selectedTripIndex!];
    final allPhotos = trip.places.expand((p) => p.photos).toList();

    return Container(
      height: 180, 
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(30)),
      child: ShaderMask(
        shaderCallback: (Rect bounds) => const LinearGradient(
          begin: Alignment.topCenter, end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.white, Colors.white, Colors.transparent],
          stops: [0.0, 0.15, 0.85, 1.0], 
        ).createShader(bounds),
        blendMode: BlendMode.dstIn,
        child: NotificationListener<ScrollNotification>(
          onNotification: (ScrollNotification info) {
            if (info is ScrollStartNotification && info.dragDetails != null) {
              _isRightListScrolling = true;
            } 
            else if (info is ScrollUpdateNotification && _isRightListScrolling) {
              double targetPage = info.metrics.pixels / 60.0;
              targetPage = targetPage.clamp(0.0, (allPhotos.length - 1).toDouble());
              if (_pageController != null && _pageController!.hasClients) {
                _pageController!.position.jumpTo(targetPage * _pageController!.position.viewportDimension * _pageController!.viewportFraction);
              }
            } 
            else if (info is ScrollEndNotification) {
              if (_isRightListScrolling) {
                _isRightListScrolling = false;
                int closestPage = (info.metrics.pixels / 60.0).round();
                _pageController?.animateToPage(closestPage, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
              }
            }
            return false;
          },
          child: ListView.builder(
            controller: _verticalScrollController,
            physics: const BouncingScrollPhysics(), 
            padding: const EdgeInsets.symmetric(vertical: 60),
            itemExtent: 60.0, 
            itemCount: allPhotos.length,
            itemBuilder: (context, idx) {
              final asset = allPhotos[idx].originalAsset;
              if (asset == null) return const SizedBox.shrink();
              
              return GestureDetector(
                onTap: () => _pageController?.animateToPage(idx, duration: const Duration(milliseconds: 300), curve: Curves.easeInOut),
                child: SizedBox(
                  height: 60.0,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                    child: ClipOval(child: AspectRatio(aspectRatio: 1, child: AssetEntityImage(asset, fit: BoxFit.cover, isOriginal: false, thumbnailSize: const pm.ThumbnailSize(60, 60)))),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildTripFilmStrip() {
    if (_pageController == null) return const SizedBox.shrink();
    final trip = _trips[_selectedTripIndex!];
    final allPhotos = trip.places.expand((p) => p.photos).toList();
    
    return SizedBox(
      height: 160, 
      child: PageView.builder(
        key: ValueKey(_selectedTripIndex), 
        controller: _pageController,
        itemCount: allPhotos.length,
        itemBuilder: (context, idx) {
          final asset = allPhotos[idx].originalAsset;
          if (asset == null) return const SizedBox.shrink();

          return AnimatedBuilder(
            animation: _pageController!,
            builder: (context, child) {
              double value = 1.0;
              if (_pageController!.hasClients && _pageController!.positions.length == 1 && _pageController!.position.haveDimensions) {
                double offset = (_pageController!.page! - idx).abs();
                value = (1 - (offset * 0.6)).clamp(0.0, 1.0);
              }
              
              double size = 60.0 + (100.0 * Curves.easeOut.transform(value));
              
              return Center(
                child: SizedBox(
                  height: size, 
                  width: size,
                  child: Opacity(opacity: value.clamp(0.4, 1.0), child: child),
                ),
              );
            },
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 5),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(15), boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 8)]),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(15), 
                child: AssetEntityImage(asset, fit: BoxFit.cover, isOriginal: false, thumbnailSize: const pm.ThumbnailSize(400, 400))
              )
            ),
          );
        },
      ),
    );
  }
}
