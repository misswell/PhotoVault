//
//  GazetteerData.swift
//  PhotoVault
//
//  The offline place database. No network, no bundled download, no lookup
//  service: a location query must resolve with the device in airplane mode.
//
//  Provenance and its limits
//  -------------------------
//  Coordinates are city-centre values to roughly 10 km, which is well inside the
//  search radius for a city or a landmark but is NOT survey data. They are
//  hand-curated rather than imported from a dataset, so the honest description is
//  "good enough to answer 在东京拍的照片, not authoritative".
//
//  The alternative -- shipping a large set of coordinates that cannot be checked
//  -- would be worse: a wrong coordinate does not fail, it silently returns
//  photos from the wrong place. A smaller set that is right, plus a loader that
//  accepts a bigger dataset unchanged, is the better trade. `OfflineGazetteer`
//  is deliberately constructed from an array so a real dataset can replace this
//  file without touching any logic.
//
//  Coverage is weighted toward what a Chinese-language photo library actually
//  contains: every province-level division of China, its major cities, and the
//  travel destinations that show up in albums, then the world cities those
//  libraries visit.
//

import Foundation

enum PlaceKind: String, Sendable, CaseIterable {
    /// A country. Resolved with a deliberately large radius: "在日本拍的" is a
    /// common query and a country is not a point, so the bounding box is coarse
    /// and over-selects rather than missing.
    case country
    /// A province, autonomous region or municipality.
    case province
    case city
    case district
    /// A named place inside a city: 天安门, 西湖, 埃菲尔铁塔.
    case landmark

    /// Search radius in kilometres. Chosen per kind rather than per entry,
    /// because the useful granularity is a property of what the place *is*.
    var defaultRadiusKilometers: Double {
        switch self {
        case .country: 900
        case .province: 250
        case .city: 30
        case .district: 8
        case .landmark: 3
        }
    }
}

struct PlaceEntry: Sendable {
    /// First name is canonical; the rest are aliases (Chinese, English, historic).
    var names: [String]
    var latitude: Double
    var longitude: Double
    var kind: PlaceKind
    /// Overrides `kind.defaultRadiusKilometers` for places that need it.
    var radiusKilometers: Double?

    var primaryName: String { names[0] }
}

enum GazetteerData {

    /// China's province-level divisions, plus the cities and destinations that
    /// dominate a domestic photo library.
    static let china: [PlaceEntry] = [
        // -- Province-level divisions --------------------------------------
        PlaceEntry(names: ["北京", "北京市", "Beijing", "Peking"], latitude: 39.9042, longitude: 116.4074, kind: .province),
        PlaceEntry(names: ["上海", "上海市", "Shanghai"], latitude: 31.2304, longitude: 121.4737, kind: .province),
        PlaceEntry(names: ["天津", "天津市", "Tianjin"], latitude: 39.3434, longitude: 117.3616, kind: .province),
        PlaceEntry(names: ["重庆", "重庆市", "Chongqing"], latitude: 29.5630, longitude: 106.5516, kind: .province),
        PlaceEntry(names: ["河北", "河北省", "Hebei"], latitude: 38.0428, longitude: 114.5149, kind: .province),
        PlaceEntry(names: ["山西", "山西省", "Shanxi"], latitude: 37.8706, longitude: 112.5489, kind: .province),
        PlaceEntry(names: ["辽宁", "辽宁省", "Liaoning"], latitude: 41.8057, longitude: 123.4315, kind: .province),
        PlaceEntry(names: ["吉林", "吉林省", "Jilin"], latitude: 43.8171, longitude: 125.3235, kind: .province),
        PlaceEntry(names: ["黑龙江", "黑龙江省", "Heilongjiang"], latitude: 45.8038, longitude: 126.5349, kind: .province),
        PlaceEntry(names: ["江苏", "江苏省", "Jiangsu"], latitude: 32.0603, longitude: 118.7969, kind: .province),
        PlaceEntry(names: ["浙江", "浙江省", "Zhejiang"], latitude: 30.2741, longitude: 120.1551, kind: .province),
        PlaceEntry(names: ["安徽", "安徽省", "Anhui"], latitude: 31.8206, longitude: 117.2272, kind: .province),
        PlaceEntry(names: ["福建", "福建省", "Fujian"], latitude: 26.0745, longitude: 119.2965, kind: .province),
        PlaceEntry(names: ["江西", "江西省", "Jiangxi"], latitude: 28.6820, longitude: 115.8579, kind: .province),
        PlaceEntry(names: ["山东", "山东省", "Shandong"], latitude: 36.6512, longitude: 117.1201, kind: .province),
        PlaceEntry(names: ["河南", "河南省", "Henan"], latitude: 34.7466, longitude: 113.6254, kind: .province),
        PlaceEntry(names: ["湖北", "湖北省", "Hubei"], latitude: 30.5928, longitude: 114.3055, kind: .province),
        PlaceEntry(names: ["湖南", "湖南省", "Hunan"], latitude: 28.2282, longitude: 112.9388, kind: .province),
        PlaceEntry(names: ["广东", "广东省", "Guangdong"], latitude: 23.1291, longitude: 113.2644, kind: .province),
        PlaceEntry(names: ["海南", "海南省", "Hainan"], latitude: 20.0444, longitude: 110.1999, kind: .province),
        PlaceEntry(names: ["四川", "四川省", "Sichuan"], latitude: 30.5728, longitude: 104.0668, kind: .province),
        PlaceEntry(names: ["贵州", "贵州省", "Guizhou"], latitude: 26.6470, longitude: 106.6302, kind: .province),
        PlaceEntry(names: ["云南", "云南省", "Yunnan"], latitude: 24.8801, longitude: 102.8329, kind: .province),
        PlaceEntry(names: ["陕西", "陕西省", "Shaanxi"], latitude: 34.3416, longitude: 108.9398, kind: .province),
        PlaceEntry(names: ["甘肃", "甘肃省", "Gansu"], latitude: 36.0611, longitude: 103.8343, kind: .province),
        PlaceEntry(names: ["青海", "青海省", "Qinghai"], latitude: 36.6171, longitude: 101.7782, kind: .province),
        PlaceEntry(names: ["内蒙古", "内蒙古自治区", "Inner Mongolia"], latitude: 40.8414, longitude: 111.7519, kind: .province),
        PlaceEntry(names: ["广西", "广西壮族自治区", "Guangxi"], latitude: 22.8170, longitude: 108.3665, kind: .province),
        PlaceEntry(names: ["西藏", "西藏自治区", "Tibet", "Xizang"], latitude: 29.6520, longitude: 91.1721, kind: .province),
        PlaceEntry(names: ["宁夏", "宁夏回族自治区", "Ningxia"], latitude: 38.4872, longitude: 106.2309, kind: .province),
        PlaceEntry(names: ["新疆", "新疆维吾尔自治区", "Xinjiang"], latitude: 43.8256, longitude: 87.6168, kind: .province),
        PlaceEntry(names: ["台湾", "台湾省", "Taiwan"], latitude: 25.0330, longitude: 121.5654, kind: .province),
        PlaceEntry(names: ["香港", "香港特别行政区", "Hong Kong"], latitude: 22.3193, longitude: 114.1694, kind: .province),
        PlaceEntry(names: ["澳门", "澳门特别行政区", "Macau", "Macao"], latitude: 22.1987, longitude: 113.5439, kind: .province),

        // -- Cities --------------------------------------------------------
        PlaceEntry(names: ["广州", "Guangzhou", "Canton"], latitude: 23.1291, longitude: 113.2644, kind: .city),
        PlaceEntry(names: ["深圳", "Shenzhen"], latitude: 22.5431, longitude: 114.0579, kind: .city),
        PlaceEntry(names: ["成都", "Chengdu"], latitude: 30.5728, longitude: 104.0668, kind: .city),
        PlaceEntry(names: ["杭州", "Hangzhou"], latitude: 30.2741, longitude: 120.1551, kind: .city),
        PlaceEntry(names: ["武汉", "Wuhan"], latitude: 30.5928, longitude: 114.3055, kind: .city),
        PlaceEntry(names: ["西安", "Xi'an", "Xian"], latitude: 34.3416, longitude: 108.9398, kind: .city),
        PlaceEntry(names: ["南京", "Nanjing"], latitude: 32.0603, longitude: 118.7969, kind: .city),
        PlaceEntry(names: ["苏州", "Suzhou"], latitude: 31.2989, longitude: 120.5853, kind: .city),
        PlaceEntry(names: ["无锡", "Wuxi"], latitude: 31.4912, longitude: 120.3119, kind: .city),
        PlaceEntry(names: ["宁波", "Ningbo"], latitude: 29.8683, longitude: 121.5440, kind: .city),
        PlaceEntry(names: ["温州", "Wenzhou"], latitude: 27.9938, longitude: 120.6994, kind: .city),
        PlaceEntry(names: ["青岛", "Qingdao", "Tsingtao"], latitude: 36.0671, longitude: 120.3826, kind: .city),
        PlaceEntry(names: ["济南", "Jinan"], latitude: 36.6512, longitude: 117.1201, kind: .city),
        PlaceEntry(names: ["大连", "Dalian"], latitude: 38.9140, longitude: 121.6147, kind: .city),
        PlaceEntry(names: ["沈阳", "Shenyang"], latitude: 41.8057, longitude: 123.4315, kind: .city),
        PlaceEntry(names: ["哈尔滨", "Harbin"], latitude: 45.8038, longitude: 126.5349, kind: .city),
        PlaceEntry(names: ["长春", "Changchun"], latitude: 43.8171, longitude: 125.3235, kind: .city),
        PlaceEntry(names: ["石家庄", "Shijiazhuang"], latitude: 38.0428, longitude: 114.5149, kind: .city),
        PlaceEntry(names: ["太原", "Taiyuan"], latitude: 37.8706, longitude: 112.5489, kind: .city),
        PlaceEntry(names: ["郑州", "Zhengzhou"], latitude: 34.7466, longitude: 113.6254, kind: .city),
        PlaceEntry(names: ["长沙", "Changsha"], latitude: 28.2282, longitude: 112.9388, kind: .city),
        PlaceEntry(names: ["合肥", "Hefei"], latitude: 31.8206, longitude: 117.2272, kind: .city),
        PlaceEntry(names: ["福州", "Fuzhou"], latitude: 26.0745, longitude: 119.2965, kind: .city),
        PlaceEntry(names: ["厦门", "Xiamen", "Amoy"], latitude: 24.4798, longitude: 118.0894, kind: .city),
        PlaceEntry(names: ["南昌", "Nanchang"], latitude: 28.6820, longitude: 115.8579, kind: .city),
        PlaceEntry(names: ["昆明", "Kunming"], latitude: 24.8801, longitude: 102.8329, kind: .city),
        PlaceEntry(names: ["贵阳", "Guiyang"], latitude: 26.6470, longitude: 106.6302, kind: .city),
        PlaceEntry(names: ["南宁", "Nanning"], latitude: 22.8170, longitude: 108.3665, kind: .city),
        PlaceEntry(names: ["海口", "Haikou"], latitude: 20.0444, longitude: 110.1999, kind: .city),
        PlaceEntry(names: ["三亚", "Sanya"], latitude: 18.2528, longitude: 109.5119, kind: .city),
        PlaceEntry(names: ["兰州", "Lanzhou"], latitude: 36.0611, longitude: 103.8343, kind: .city),
        PlaceEntry(names: ["西宁", "Xining"], latitude: 36.6171, longitude: 101.7782, kind: .city),
        PlaceEntry(names: ["银川", "Yinchuan"], latitude: 38.4872, longitude: 106.2309, kind: .city),
        PlaceEntry(names: ["乌鲁木齐", "Urumqi"], latitude: 43.8256, longitude: 87.6168, kind: .city),
        PlaceEntry(names: ["拉萨", "Lhasa"], latitude: 29.6520, longitude: 91.1721, kind: .city),
        PlaceEntry(names: ["呼和浩特", "Hohhot"], latitude: 40.8414, longitude: 111.7519, kind: .city),
        PlaceEntry(names: ["佛山", "Foshan"], latitude: 23.0219, longitude: 113.1214, kind: .city),
        PlaceEntry(names: ["东莞", "Dongguan"], latitude: 23.0207, longitude: 113.7518, kind: .city),
        PlaceEntry(names: ["珠海", "Zhuhai"], latitude: 22.2710, longitude: 113.5767, kind: .city),
        PlaceEntry(names: ["澳门半岛"], latitude: 22.1987, longitude: 113.5439, kind: .city),
        PlaceEntry(names: ["台北", "Taipei"], latitude: 25.0330, longitude: 121.5654, kind: .city),
        PlaceEntry(names: ["高雄", "Kaohsiung"], latitude: 22.6273, longitude: 120.3014, kind: .city),

        // -- Destinations that show up in albums ---------------------------
        PlaceEntry(names: ["桂林", "Guilin"], latitude: 25.2736, longitude: 110.2900, kind: .city),
        PlaceEntry(names: ["阳朔", "Yangshuo"], latitude: 24.7785, longitude: 110.4966, kind: .city),
        PlaceEntry(names: ["丽江", "Lijiang"], latitude: 26.8721, longitude: 100.2299, kind: .city),
        PlaceEntry(names: ["大理", "Dali"], latitude: 25.6065, longitude: 100.2676, kind: .city),
        PlaceEntry(names: ["香格里拉", "Shangri-La"], latitude: 27.8253, longitude: 99.7068, kind: .city),
        PlaceEntry(names: ["敦煌", "Dunhuang"], latitude: 40.1421, longitude: 94.6618, kind: .city),
        PlaceEntry(names: ["张家界", "Zhangjiajie"], latitude: 29.1170, longitude: 110.4790, kind: .city),
        PlaceEntry(names: ["黄山", "Huangshan"], latitude: 29.7147, longitude: 118.3376, kind: .city),
        PlaceEntry(names: ["九寨沟", "Jiuzhaigou"], latitude: 33.2600, longitude: 103.9180, kind: .city),
        PlaceEntry(names: ["西双版纳", "Xishuangbanna"], latitude: 22.0017, longitude: 100.7977, kind: .city),
        PlaceEntry(names: ["呼伦贝尔", "Hulunbuir"], latitude: 49.2122, longitude: 119.7658, kind: .city),
        PlaceEntry(names: ["泰山", "Mount Tai"], latitude: 36.2550, longitude: 117.1000, kind: .landmark),
        PlaceEntry(names: ["华山", "Mount Hua"], latitude: 34.4833, longitude: 110.0833, kind: .landmark),
        PlaceEntry(names: ["峨眉山", "Mount Emei"], latitude: 29.5200, longitude: 103.3320, kind: .landmark),

        // -- Landmarks -----------------------------------------------------
        PlaceEntry(names: ["天安门", "天安门广场", "Tiananmen"], latitude: 39.9055, longitude: 116.3976, kind: .landmark),
        PlaceEntry(names: ["故宫", "紫禁城", "Forbidden City"], latitude: 39.9163, longitude: 116.3972, kind: .landmark),
        PlaceEntry(names: ["长城", "八达岭长城", "Great Wall"], latitude: 40.3597, longitude: 116.0199, kind: .landmark),
        PlaceEntry(names: ["颐和园", "Summer Palace"], latitude: 39.9999, longitude: 116.2755, kind: .landmark),
        PlaceEntry(names: ["鸟巢", "国家体育场"], latitude: 39.9928, longitude: 116.3964, kind: .landmark),
        PlaceEntry(names: ["外滩", "The Bund"], latitude: 31.2397, longitude: 121.4900, kind: .landmark),
        PlaceEntry(names: ["东方明珠", "Oriental Pearl"], latitude: 31.2397, longitude: 121.4998, kind: .landmark),
        PlaceEntry(names: ["上海迪士尼", "Shanghai Disneyland"], latitude: 31.1434, longitude: 121.6578, kind: .landmark),
        PlaceEntry(names: ["西湖", "West Lake"], latitude: 30.2427, longitude: 120.1502, kind: .landmark),
        PlaceEntry(names: ["兵马俑", "秦始皇兵马俑", "Terracotta Army"], latitude: 34.3841, longitude: 109.2785, kind: .landmark),
        PlaceEntry(names: ["布达拉宫", "Potala Palace"], latitude: 29.6577, longitude: 91.1170, kind: .landmark),
        PlaceEntry(names: ["广州塔", "小蛮腰", "Canton Tower"], latitude: 23.1066, longitude: 113.3245, kind: .landmark),
        PlaceEntry(names: ["香港迪士尼", "Hong Kong Disneyland"], latitude: 22.3130, longitude: 114.0413, kind: .landmark),
        PlaceEntry(names: ["日月潭", "Sun Moon Lake"], latitude: 23.8658, longitude: 120.9158, kind: .landmark),
        PlaceEntry(names: ["台北101", "Taipei 101"], latitude: 25.0339, longitude: 121.5645, kind: .landmark),
    ]

    /// Major world cities and landmarks, weighted toward destinations a Chinese
    /// photo library is likely to contain.
    static let world: [PlaceEntry] = [
        // -- Asia ----------------------------------------------------------
        PlaceEntry(names: ["日本", "Japan"], latitude: 35.6762, longitude: 139.6503, kind: .country),
        PlaceEntry(names: ["东京", "Tokyo"], latitude: 35.6762, longitude: 139.6503, kind: .city),
        PlaceEntry(names: ["大阪", "Osaka"], latitude: 34.6937, longitude: 135.5023, kind: .city),
        PlaceEntry(names: ["京都", "Kyoto"], latitude: 35.0116, longitude: 135.7681, kind: .city),
        PlaceEntry(names: ["北海道", "Hokkaido"], latitude: 43.0621, longitude: 141.3544, kind: .province),
        PlaceEntry(names: ["札幌", "Sapporo"], latitude: 43.0618, longitude: 141.3545, kind: .city),
        PlaceEntry(names: ["冲绳", "Okinawa"], latitude: 26.3344, longitude: 127.8056, kind: .province),
        PlaceEntry(names: ["名古屋", "Nagoya"], latitude: 35.1815, longitude: 136.9066, kind: .city),
        PlaceEntry(names: ["富士山", "Mount Fuji"], latitude: 35.3606, longitude: 138.7274, kind: .landmark),
        PlaceEntry(names: ["东京塔", "Tokyo Tower"], latitude: 35.6586, longitude: 139.7454, kind: .landmark),
        PlaceEntry(names: ["韩国", "South Korea", "Korea"], latitude: 37.5665, longitude: 126.9780, kind: .country),
        PlaceEntry(names: ["首尔", "Seoul"], latitude: 37.5665, longitude: 126.9780, kind: .city),
        PlaceEntry(names: ["釜山", "Busan"], latitude: 35.1796, longitude: 129.0756, kind: .city),
        PlaceEntry(names: ["济州岛", "Jeju"], latitude: 33.4996, longitude: 126.5312, kind: .province),
        PlaceEntry(names: ["泰国", "Thailand"], latitude: 13.7563, longitude: 100.5018, kind: .country),
        PlaceEntry(names: ["曼谷", "Bangkok"], latitude: 13.7563, longitude: 100.5018, kind: .city),
        PlaceEntry(names: ["清迈", "Chiang Mai"], latitude: 18.7883, longitude: 98.9853, kind: .city),
        PlaceEntry(names: ["普吉岛", "Phuket"], latitude: 7.8804, longitude: 98.3923, kind: .province),
        PlaceEntry(names: ["新加坡", "Singapore"], latitude: 1.3521, longitude: 103.8198, kind: .country),
        PlaceEntry(names: ["马来西亚", "Malaysia"], latitude: 3.1390, longitude: 101.6869, kind: .country),
        PlaceEntry(names: ["吉隆坡", "Kuala Lumpur"], latitude: 3.1390, longitude: 101.6869, kind: .city),
        PlaceEntry(names: ["沙巴", "Sabah"], latitude: 5.9804, longitude: 116.0735, kind: .province),
        PlaceEntry(names: ["印度尼西亚", "Indonesia"], latitude: -6.2088, longitude: 106.8456, kind: .country),
        PlaceEntry(names: ["巴厘岛", "Bali"], latitude: -8.4095, longitude: 115.1889, kind: .province),
        PlaceEntry(names: ["雅加达", "Jakarta"], latitude: -6.2088, longitude: 106.8456, kind: .city),
        PlaceEntry(names: ["越南", "Vietnam"], latitude: 21.0285, longitude: 105.8542, kind: .country),
        PlaceEntry(names: ["河内", "Hanoi"], latitude: 21.0285, longitude: 105.8542, kind: .city),
        PlaceEntry(names: ["胡志明市", "Ho Chi Minh City", "Saigon"], latitude: 10.8231, longitude: 106.6297, kind: .city),
        PlaceEntry(names: ["岘港", "Da Nang"], latitude: 16.0544, longitude: 108.2022, kind: .city),
        PlaceEntry(names: ["柬埔寨", "Cambodia"], latitude: 11.5564, longitude: 104.9282, kind: .country),
        PlaceEntry(names: ["吴哥窟", "Angkor Wat"], latitude: 13.4125, longitude: 103.8670, kind: .landmark),
        PlaceEntry(names: ["印度", "India"], latitude: 28.6139, longitude: 77.2090, kind: .country),
        PlaceEntry(names: ["新德里", "New Delhi", "Delhi"], latitude: 28.6139, longitude: 77.2090, kind: .city),
        PlaceEntry(names: ["泰姬陵", "Taj Mahal"], latitude: 27.1751, longitude: 78.0421, kind: .landmark),
        PlaceEntry(names: ["马尔代夫", "Maldives"], latitude: 4.1755, longitude: 73.5093, kind: .country),
        PlaceEntry(names: ["迪拜", "Dubai"], latitude: 25.2048, longitude: 55.2708, kind: .city),
        PlaceEntry(names: ["阿联酋", "United Arab Emirates", "UAE"], latitude: 24.4539, longitude: 54.3773, kind: .country),
        PlaceEntry(names: ["土耳其", "Turkey", "Türkiye"], latitude: 41.0082, longitude: 28.9784, kind: .country),
        PlaceEntry(names: ["伊斯坦布尔", "Istanbul"], latitude: 41.0082, longitude: 28.9784, kind: .city),
        PlaceEntry(names: ["卡帕多奇亚", "Cappadocia"], latitude: 38.6431, longitude: 34.8289, kind: .landmark),

        // -- Europe --------------------------------------------------------
        PlaceEntry(names: ["英国", "United Kingdom", "UK", "Britain"], latitude: 51.5074, longitude: -0.1278, kind: .country),
        PlaceEntry(names: ["伦敦", "London"], latitude: 51.5074, longitude: -0.1278, kind: .city),
        PlaceEntry(names: ["爱丁堡", "Edinburgh"], latitude: 55.9533, longitude: -3.1883, kind: .city),
        PlaceEntry(names: ["曼彻斯特", "Manchester"], latitude: 53.4808, longitude: -2.2426, kind: .city),
        PlaceEntry(names: ["大本钟", "Big Ben"], latitude: 51.5007, longitude: -0.1246, kind: .landmark),
        PlaceEntry(names: ["伦敦塔桥", "Tower Bridge"], latitude: 51.5055, longitude: -0.0754, kind: .landmark),
        PlaceEntry(names: ["法国", "France"], latitude: 48.8566, longitude: 2.3522, kind: .country),
        PlaceEntry(names: ["巴黎", "Paris"], latitude: 48.8566, longitude: 2.3522, kind: .city),
        PlaceEntry(names: ["尼斯", "Nice"], latitude: 43.7102, longitude: 7.2620, kind: .city),
        PlaceEntry(names: ["普罗旺斯", "Provence"], latitude: 43.9352, longitude: 5.0677, kind: .province),
        PlaceEntry(names: ["埃菲尔铁塔", "Eiffel Tower"], latitude: 48.8584, longitude: 2.2945, kind: .landmark),
        PlaceEntry(names: ["卢浮宫", "Louvre"], latitude: 48.8606, longitude: 2.3376, kind: .landmark),
        PlaceEntry(names: ["凡尔赛宫", "Versailles"], latitude: 48.8049, longitude: 2.1204, kind: .landmark),
        PlaceEntry(names: ["意大利", "Italy"], latitude: 41.9028, longitude: 12.4964, kind: .country),
        PlaceEntry(names: ["罗马", "Rome"], latitude: 41.9028, longitude: 12.4964, kind: .city),
        PlaceEntry(names: ["米兰", "Milan"], latitude: 45.4642, longitude: 9.1900, kind: .city),
        PlaceEntry(names: ["威尼斯", "Venice"], latitude: 45.4408, longitude: 12.3155, kind: .city),
        PlaceEntry(names: ["佛罗伦萨", "Florence"], latitude: 43.7696, longitude: 11.2558, kind: .city),
        PlaceEntry(names: ["斗兽场", "Colosseum"], latitude: 41.8902, longitude: 12.4922, kind: .landmark),
        PlaceEntry(names: ["西班牙", "Spain"], latitude: 40.4168, longitude: -3.7038, kind: .country),
        PlaceEntry(names: ["马德里", "Madrid"], latitude: 40.4168, longitude: -3.7038, kind: .city),
        PlaceEntry(names: ["巴塞罗那", "Barcelona"], latitude: 41.3874, longitude: 2.1686, kind: .city),
        PlaceEntry(names: ["圣家堂", "Sagrada Familia"], latitude: 41.4036, longitude: 2.1744, kind: .landmark),
        PlaceEntry(names: ["葡萄牙", "Portugal"], latitude: 38.7223, longitude: -9.1393, kind: .country),
        PlaceEntry(names: ["里斯本", "Lisbon"], latitude: 38.7223, longitude: -9.1393, kind: .city),
        PlaceEntry(names: ["德国", "Germany"], latitude: 52.5200, longitude: 13.4050, kind: .country),
        PlaceEntry(names: ["柏林", "Berlin"], latitude: 52.5200, longitude: 13.4050, kind: .city),
        PlaceEntry(names: ["慕尼黑", "Munich"], latitude: 48.1351, longitude: 11.5820, kind: .city),
        PlaceEntry(names: ["法兰克福", "Frankfurt"], latitude: 50.1109, longitude: 8.6821, kind: .city),
        PlaceEntry(names: ["新天鹅堡", "Neuschwanstein"], latitude: 47.5576, longitude: 10.7498, kind: .landmark),
        PlaceEntry(names: ["荷兰", "Netherlands", "Holland"], latitude: 52.3676, longitude: 4.9041, kind: .country),
        PlaceEntry(names: ["阿姆斯特丹", "Amsterdam"], latitude: 52.3676, longitude: 4.9041, kind: .city),
        PlaceEntry(names: ["瑞士", "Switzerland"], latitude: 47.3769, longitude: 8.5417, kind: .country),
        PlaceEntry(names: ["苏黎世", "Zurich"], latitude: 47.3769, longitude: 8.5417, kind: .city),
        PlaceEntry(names: ["日内瓦", "Geneva"], latitude: 46.2044, longitude: 6.1432, kind: .city),
        PlaceEntry(names: ["因特拉肯", "Interlaken"], latitude: 46.6863, longitude: 7.8632, kind: .city),
        PlaceEntry(names: ["少女峰", "Jungfrau"], latitude: 46.5367, longitude: 7.9625, kind: .landmark),
        PlaceEntry(names: ["奥地利", "Austria"], latitude: 48.2082, longitude: 16.3738, kind: .country),
        PlaceEntry(names: ["维也纳", "Vienna"], latitude: 48.2082, longitude: 16.3738, kind: .city),
        PlaceEntry(names: ["捷克", "Czech Republic", "Czechia"], latitude: 50.0755, longitude: 14.4378, kind: .country),
        PlaceEntry(names: ["布拉格", "Prague"], latitude: 50.0755, longitude: 14.4378, kind: .city),
        PlaceEntry(names: ["匈牙利", "Hungary"], latitude: 47.4979, longitude: 19.0402, kind: .country),
        PlaceEntry(names: ["布达佩斯", "Budapest"], latitude: 47.4979, longitude: 19.0402, kind: .city),
        PlaceEntry(names: ["希腊", "Greece"], latitude: 37.9838, longitude: 23.7275, kind: .country),
        PlaceEntry(names: ["雅典", "Athens"], latitude: 37.9838, longitude: 23.7275, kind: .city),
        PlaceEntry(names: ["圣托里尼", "Santorini"], latitude: 36.3932, longitude: 25.4615, kind: .province),
        PlaceEntry(names: ["丹麦", "Denmark"], latitude: 55.6761, longitude: 12.5683, kind: .country),
        PlaceEntry(names: ["哥本哈根", "Copenhagen"], latitude: 55.6761, longitude: 12.5683, kind: .city),
        PlaceEntry(names: ["瑞典", "Sweden"], latitude: 59.3293, longitude: 18.0686, kind: .country),
        PlaceEntry(names: ["斯德哥尔摩", "Stockholm"], latitude: 59.3293, longitude: 18.0686, kind: .city),
        PlaceEntry(names: ["挪威", "Norway"], latitude: 59.9139, longitude: 10.7522, kind: .country),
        PlaceEntry(names: ["奥斯陆", "Oslo"], latitude: 59.9139, longitude: 10.7522, kind: .city),
        PlaceEntry(names: ["芬兰", "Finland"], latitude: 60.1699, longitude: 24.9384, kind: .country),
        PlaceEntry(names: ["赫尔辛基", "Helsinki"], latitude: 60.1699, longitude: 24.9384, kind: .city),
        PlaceEntry(names: ["冰岛", "Iceland"], latitude: 64.1466, longitude: -21.9426, kind: .country),
        PlaceEntry(names: ["雷克雅未克", "Reykjavik"], latitude: 64.1466, longitude: -21.9426, kind: .city),
        PlaceEntry(names: ["爱尔兰", "Ireland"], latitude: 53.3498, longitude: -6.2603, kind: .country),
        PlaceEntry(names: ["都柏林", "Dublin"], latitude: 53.3498, longitude: -6.2603, kind: .city),
        PlaceEntry(names: ["俄罗斯", "Russia"], latitude: 55.7558, longitude: 37.6173, kind: .country),
        PlaceEntry(names: ["莫斯科", "Moscow"], latitude: 55.7558, longitude: 37.6173, kind: .city),
        PlaceEntry(names: ["圣彼得堡", "Saint Petersburg"], latitude: 59.9311, longitude: 30.3609, kind: .city),

        // -- Americas ------------------------------------------------------
        PlaceEntry(names: ["美国", "United States", "USA", "America"], latitude: 40.7128, longitude: -74.0060, kind: .country),
        PlaceEntry(names: ["纽约", "New York"], latitude: 40.7128, longitude: -74.0060, kind: .city),
        PlaceEntry(names: ["洛杉矶", "Los Angeles"], latitude: 34.0522, longitude: -118.2437, kind: .city),
        PlaceEntry(names: ["旧金山", "San Francisco"], latitude: 37.7749, longitude: -122.4194, kind: .city),
        PlaceEntry(names: ["西雅图", "Seattle"], latitude: 47.6062, longitude: -122.3321, kind: .city),
        PlaceEntry(names: ["芝加哥", "Chicago"], latitude: 41.8781, longitude: -87.6298, kind: .city),
        PlaceEntry(names: ["波士顿", "Boston"], latitude: 42.3601, longitude: -71.0589, kind: .city),
        PlaceEntry(names: ["华盛顿", "Washington"], latitude: 38.9072, longitude: -77.0369, kind: .city),
        PlaceEntry(names: ["拉斯维加斯", "Las Vegas"], latitude: 36.1699, longitude: -115.1398, kind: .city),
        PlaceEntry(names: ["迈阿密", "Miami"], latitude: 25.7617, longitude: -80.1918, kind: .city),
        PlaceEntry(names: ["檀香山", "Honolulu", "Hawaii"], latitude: 21.3069, longitude: -157.8583, kind: .city),
        PlaceEntry(names: ["黄石公园", "Yellowstone"], latitude: 44.4280, longitude: -110.5885, kind: .landmark),
        PlaceEntry(names: ["大峡谷", "Grand Canyon"], latitude: 36.1069, longitude: -112.1129, kind: .landmark),
        PlaceEntry(names: ["自由女神像", "Statue of Liberty"], latitude: 40.6892, longitude: -74.0445, kind: .landmark),
        PlaceEntry(names: ["金门大桥", "Golden Gate Bridge"], latitude: 37.8199, longitude: -122.4783, kind: .landmark),
        PlaceEntry(names: ["加拿大", "Canada"], latitude: 43.6532, longitude: -79.3832, kind: .country),
        PlaceEntry(names: ["多伦多", "Toronto"], latitude: 43.6532, longitude: -79.3832, kind: .city),
        PlaceEntry(names: ["温哥华", "Vancouver"], latitude: 49.2827, longitude: -123.1207, kind: .city),
        PlaceEntry(names: ["班夫", "Banff"], latitude: 51.1784, longitude: -115.5708, kind: .landmark),
        PlaceEntry(names: ["墨西哥", "Mexico"], latitude: 19.4326, longitude: -99.1332, kind: .country),
        PlaceEntry(names: ["墨西哥城", "Mexico City"], latitude: 19.4326, longitude: -99.1332, kind: .city),
        PlaceEntry(names: ["巴西", "Brazil"], latitude: -22.9068, longitude: -43.1729, kind: .country),
        PlaceEntry(names: ["里约热内卢", "Rio de Janeiro"], latitude: -22.9068, longitude: -43.1729, kind: .city),
        PlaceEntry(names: ["圣保罗", "São Paulo", "Sao Paulo"], latitude: -23.5505, longitude: -46.6333, kind: .city),
        PlaceEntry(names: ["阿根廷", "Argentina"], latitude: -34.6037, longitude: -58.3816, kind: .country),
        PlaceEntry(names: ["布宜诺斯艾利斯", "Buenos Aires"], latitude: -34.6037, longitude: -58.3816, kind: .city),
        PlaceEntry(names: ["秘鲁", "Peru"], latitude: -12.0464, longitude: -77.0428, kind: .country),
        PlaceEntry(names: ["马丘比丘", "Machu Picchu"], latitude: -13.1631, longitude: -72.5450, kind: .landmark),

        // -- Oceania and Africa --------------------------------------------
        PlaceEntry(names: ["澳大利亚", "澳洲", "Australia"], latitude: -33.8688, longitude: 151.2093, kind: .country),
        PlaceEntry(names: ["悉尼", "Sydney"], latitude: -33.8688, longitude: 151.2093, kind: .city),
        PlaceEntry(names: ["墨尔本", "Melbourne"], latitude: -37.8136, longitude: 144.9631, kind: .city),
        PlaceEntry(names: ["布里斯班", "Brisbane"], latitude: -27.4698, longitude: 153.0251, kind: .city),
        PlaceEntry(names: ["黄金海岸", "Gold Coast"], latitude: -28.0167, longitude: 153.4000, kind: .city),
        PlaceEntry(names: ["悉尼歌剧院", "Sydney Opera House"], latitude: -33.8568, longitude: 151.2153, kind: .landmark),
        PlaceEntry(names: ["新西兰", "New Zealand"], latitude: -36.8485, longitude: 174.7633, kind: .country),
        PlaceEntry(names: ["奥克兰", "Auckland"], latitude: -36.8485, longitude: 174.7633, kind: .city),
        PlaceEntry(names: ["皇后镇", "Queenstown"], latitude: -45.0312, longitude: 168.6626, kind: .city),
        PlaceEntry(names: ["埃及", "Egypt"], latitude: 30.0444, longitude: 31.2357, kind: .country),
        PlaceEntry(names: ["开罗", "Cairo"], latitude: 30.0444, longitude: 31.2357, kind: .city),
        PlaceEntry(names: ["金字塔", "吉萨金字塔", "Pyramids of Giza"], latitude: 29.9792, longitude: 31.1342, kind: .landmark),
        PlaceEntry(names: ["南非", "South Africa"], latitude: -33.9249, longitude: 18.4241, kind: .country),
        PlaceEntry(names: ["开普敦", "Cape Town"], latitude: -33.9249, longitude: 18.4241, kind: .city),
        PlaceEntry(names: ["肯尼亚", "Kenya"], latitude: -1.2921, longitude: 36.8219, kind: .country),
        PlaceEntry(names: ["内罗毕", "Nairobi"], latitude: -1.2921, longitude: 36.8219, kind: .city),
        PlaceEntry(names: ["摩洛哥", "Morocco"], latitude: 31.6295, longitude: -7.9811, kind: .country),
        PlaceEntry(names: ["马拉喀什", "Marrakesh"], latitude: 31.6295, longitude: -7.9811, kind: .city),
    ]

    static var all: [PlaceEntry] { china + world }
}
