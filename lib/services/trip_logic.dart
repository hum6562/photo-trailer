import 'dart:math';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:photo_manager/photo_manager.dart' as pm;

class RawPhoto {
  final String id;
  LatLng? location;
  final DateTime time;
  final double width;
  final double height;
  final bool isFavorite;
  double score = 0.0;
  int? clusterId;
  final pm.AssetEntity? originalAsset;

  // 모든 final 변수를 생성자에서 확실하게 초기화합니다.
  RawPhoto({
    required this.id,
    this.location,
    required this.time,
    required this.width,
    required this.height,
    required this.isFavorite,
    this.originalAsset,
  });

  bool get hasGps => location != null && location!.latitude != 0;
}

class Place {
  final LatLng centroid;
  final List<RawPhoto> photos;
  final DateTime arrival;
  final DateTime departure;
  late RawPhoto representative;

  Place({
    required this.centroid, 
    required this.photos, 
    required this.arrival, 
    required this.departure
  });

  DateTime get middleTime => arrival.add(departure.difference(arrival) ~/ 2);
}

class Trip {
  final String title;
  final DateTime start;
  final DateTime end;
  final List<Place> places;
  final List<LatLng> path;

  Trip({
    required this.title, 
    required this.start, 
    required this.end, 
    required this.places, 
    required this.path
  });
}

class UltimateTravelEngine {
  final double kGridRes = 0.005;
  final double kHomeRadius = 15.0;
  final double kDistanceJump = 80.0;
  final int kTripMaxGapHours = 36;
  final int kMinTripStayMinutes = 180;
  final double kDbscanEps = 0.2;
  final int kDbscanMinPts = 3;
  final int kPlaceMaxGapMinutes = 60;
  final double kMaxVelocityKmh = 120.0;

  List<Trip> segment(List<RawPhoto> rawPhotos) {
    if (rawPhotos.isEmpty) return [];
    for (var p in rawPhotos) { p.clusterId = null; }

    var photos = _preprocess(rawPhotos);
    var homes = _detectTopHomes(photos, topN: 2);
    if (homes.isEmpty) return [];

    List<Trip> trips = [];
    List<RawPhoto> currentTripPhotos = [];
    bool isTraveling = false;

    for (int i = 0; i < photos.length; i++) {
      var p = photos[i];
      if (!p.hasGps || p.location == null) continue; // 널 방지
      
      double minDistFromHome = homes.map((h) => _getDist(p.location!, h)).reduce(min);

      if (!isTraveling) {
        double distFromPrev = i > 0 && photos[i - 1].hasGps && photos[i-1].location != null 
            ? _getDist(photos[i - 1].location!, p.location!) : 0;
        if (minDistFromHome > kHomeRadius || distFromPrev > kDistanceJump) {
          isTraveling = true;
          currentTripPhotos = [p];
        }
      } else {
        int timeGap = p.time.difference(currentTripPhotos.last.time).inHours;
        bool isHomeEntry = minDistFromHome < kHomeRadius * 0.7 && timeGap >= 2;
        bool isInactive = timeGap >= kTripMaxGapHours;

        if (isHomeEntry || isInactive) {
          var trip = _finalizeTrip(currentTripPhotos);
          if (trip != null && trip.end.difference(trip.start).inMinutes >= kMinTripStayMinutes) {
            trips.add(trip);
          }
          isTraveling = false;
          currentTripPhotos = [];
        } else {
          currentTripPhotos.add(p);
        }
      }
    }
    if (isTraveling && currentTripPhotos.length >= 5) {
      var trip = _finalizeTrip(currentTripPhotos);
      if (trip != null) trips.add(trip);
    }
    return trips;
  }

  Trip? _finalizeTrip(List<RawPhoto> photos) {
    if (photos.isEmpty) return null;
    var places = _clusterPlaces(photos);
    if (places.isEmpty) return null;

    return Trip(
      title: "${photos.first.time.month}/${photos.first.time.day} 여행",
      start: photos.first.time,
      end: photos.last.time,
      places: places,
      path: places.map((pl) => pl.centroid).toList(),
    );
  }

  List<Place> _clusterPlaces(List<RawPhoto> photos) {
    var gpsPhotos = photos.where((p) => p.hasGps && p.location != null).toList();
    if (gpsPhotos.isEmpty) return [];

    int currentCid = 0;
    for (int i = 0; i < gpsPhotos.length; i++) {
      if (gpsPhotos[i].clusterId != null) continue;
      var neighbors = _getNeighbors(gpsPhotos, i);
      if (neighbors.length < kDbscanMinPts) {
        gpsPhotos[i].clusterId = -1;
      } else {
        currentCid++;
        _expandCluster(gpsPhotos, i, neighbors, currentCid);
      }
    }

    Map<int, List<RawPhoto>> groups = {};
    for (var p in gpsPhotos) {
      if (p.clusterId != null && p.clusterId! > 0) {
        groups.putIfAbsent(p.clusterId!, () => []).add(p);
      }
    }

    return groups.values.map((g) {
      var pl = Place(
        centroid: _calculateCentroid(g), 
        photos: g, 
        arrival: g.first.time, 
        departure: g.last.time
      );
      pl.representative = _selectBestPhoto(pl);
      return pl;
    }).toList();
  }

  List<int> _getNeighbors(List<RawPhoto> all, int targetIdx) {
    List<int> neighbors = [];
    var target = all[targetIdx];
    if (target.location == null) return neighbors;

    for (int i = 0; i < all.length; i++) {
      if (all[i].location == null) continue;
      if (all[i].time.difference(target.time).inMinutes.abs() <= kPlaceMaxGapMinutes) {
        if (_getDist(target.location!, all[i].location!) <= kDbscanEps) {
          neighbors.add(i);
        }
      }
    }
    return neighbors;
  }

  void _expandCluster(List<RawPhoto> all, int root, List<int> neighbors, int cid) {
    all[root].clusterId = cid;
    Set<int> seeds = Set.from(neighbors);
    List<int> queue = List.from(neighbors);
    int i = 0;
    while (i < queue.length) {
      int curr = queue[i];
      if (all[curr].clusterId == -1) all[curr].clusterId = cid;
      if (all[curr].clusterId == null) {
        all[curr].clusterId = cid;
        var nextN = _getNeighbors(all, curr);
        if (nextN.length >= kDbscanMinPts) {
          for (var n in nextN) { if (seeds.add(n)) queue.add(n); }
        }
      }
      i++;
    }
  }

  List<LatLng> _detectTopHomes(List<RawPhoto> photos, {int topN = 2}) {
    Map<String, double> scores = {};
    for (var p in photos.where((p) => p.hasGps && p.location != null)) {
      String key = "${(p.location!.latitude / kGridRes).floor()},${(p.location!.longitude / kGridRes).floor()}";
      double w = (p.time.hour >= 21 || p.time.hour <= 6) ? 3.0 : 1.0;
      scores[key] = (scores[key] ?? 0) + w;
    }
    var sorted = scores.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return sorted.take(topN).map((e) {
      var parts = e.key.split(',');
      return LatLng(double.parse(parts[0]) * kGridRes, double.parse(parts[1]) * kGridRes);
    }).toList();
  }

  RawPhoto _selectBestPhoto(Place place) {
    for (var p in place.photos) {
      if (p.location == null) { p.score = 0; continue; }
      double res = min((p.width * p.height) / 12000000, 1.0);
      double spatC = 1.0 / (1.0 + _getDist(p.location!, place.centroid));
      p.score = (res * 0.5) + (spatC * 0.5);
    }
    return place.photos.reduce((a, b) => a.score > b.score ? a : b);
  }

  List<RawPhoto> _preprocess(List<RawPhoto> photos) {
    photos.sort((a, b) => a.time.compareTo(b.time));
    return photos;
  }

  double _getDist(LatLng p1, LatLng p2) {
    var p = 0.017453292519943295;
    var a = 0.5 - cos((p2.latitude - p1.latitude) * p) / 2 + 
        cos(p1.latitude * p) * cos(p2.latitude * p) * (1 - cos((p2.longitude - p1.longitude) * p)) / 2;
    return 12742 * asin(sqrt(a));
  }

  LatLng _calculateCentroid(List<RawPhoto> photos) {
    double lat = photos.map((p) => p.location!.latitude).reduce((a, b) => a + b) / photos.length;
    double lng = photos.map((p) => p.location!.longitude).reduce((a, b) => a + b) / photos.length;
    return LatLng(lat, lng);
  }
}