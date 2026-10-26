import Foundation
import LocPilotKit

/// 中国区坐标转换用例：MapKit(GCJ-02) ↔ 设备/后端(WGS-84)。
func registerChinaCoordinateTests() {
    test("坐标转换：WGS→GCJ 与标准算法一致（天安门）") {
        let gcj = ChinaCoordinate.wgs84ToGcj02(lat: 39.9087, lon: 116.3975)
        expect(abs(gcj.lat - 39.910103) < 1e-5, "GCJ lat=\(gcj.lat)，应约为 39.910103")
        expect(abs(gcj.lon - 116.403744) < 1e-5, "GCJ lon=\(gcj.lon)，应约为 116.403744")
    }

    test("坐标转换：GCJ→WGS 反解静安寺 GCJ") {
        // 高德 POI 静安寺 GCJ=(31.223505,121.445320)，对应 WGS≈(31.225375,121.440708)
        let wgs = ChinaCoordinate.gcj02ToWgs84(lat: 31.223505, lon: 121.445320)
        expect(abs(wgs.lat - 31.225375) < 5e-6, "WGS lat=\(wgs.lat)")
        expect(abs(wgs.lon - 121.440708) < 5e-6, "WGS lon=\(wgs.lon)")
    }

    test("坐标转换：大陆 display/wgs 往返误差 < 1 m") {
        let points = [(31.2397, 121.4997), (39.9087, 116.3975), (23.1291, 113.2644), (45.75, 126.65)]
        for (lat, lon) in points {
            let display = ChinaCoordinate.display(lat: lat, lon: lon)
            let back = ChinaCoordinate.wgs(lat: display.lat, lon: display.lon)
            expect(abs(back.lat - lat) < 1e-5, "往返 lat 漂移 \(back.lat - lat)")
            expect(abs(back.lon - lon) < 1e-5, "往返 lon 漂移 \(back.lon - lon)")
        }
    }

    test("坐标转换：境外与港澳台不偏移") {
        let points = [(35.6762, 139.6503), (22.3193, 114.1694), (25.0330, 121.5654),
                      (37.5665, 126.9780), (1.3521, 103.8198)]
        for (lat, lon) in points {
            let display = ChinaCoordinate.display(lat: lat, lon: lon)
            expectEqual(display.lat, lat, "境外 display 不应偏移 lat")
            expectEqual(display.lon, lon, "境外 display 不应偏移 lon")
            let wgs = ChinaCoordinate.wgs(lat: display.lat, lon: display.lon)
            expectEqual(wgs.lat, lat, "境外 wgs 不应偏移 lat")
            expectEqual(wgs.lon, lon, "境外 wgs 不应偏移 lon")
        }
    }

    test("坐标转换：大陆与境外区域判断") {
        expect(ChinaCoordinate.isMainland(lat: 31.2304, lon: 121.4737), "上海应算大陆")
        expect(ChinaCoordinate.isMainland(lat: 39.9087, lon: 116.3975), "北京应算大陆")
        expect(!ChinaCoordinate.isMainland(lat: 22.3193, lon: 114.1694), "香港不应算大陆")
        expect(!ChinaCoordinate.isMainland(lat: 25.0330, lon: 121.5654), "台北不应算大陆")
        expect(!ChinaCoordinate.isMainland(lat: 35.6762, lon: 139.6503), "东京不应算大陆")
        expect(!ChinaCoordinate.isMainland(lat: 47.8864, lon: 106.9057), "乌兰巴托不应算大陆")
    }

    test("坐标转换：东方明珠的 WGS 转换为高德 GCJ 附近") {
        // Wikipedia WGS=(31.2419,121.49526)；高德 GCJ≈(31.239703,121.499718)
        let gcj = ChinaCoordinate.display(lat: 31.2419, lon: 121.49526)
        expect(abs(gcj.lat - 31.239703) < 0.001, "GCJ lat=\(gcj.lat)")
        expect(abs(gcj.lon - 121.499718) < 0.001, "GCJ lon=\(gcj.lon)")
    }
}
