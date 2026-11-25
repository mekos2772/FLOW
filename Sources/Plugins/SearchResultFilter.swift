import Foundation

/// 针对外部视频站/通用音源插件的源无关音乐结果过滤器与重排器。
///
/// 解决第三方插件（如全站视频抓取插件）搜通用词歌名时，返回满屏游戏实况、攻略、
/// 动漫解说、影视吐槽、历史科普长视频的问题：
/// 1. 仅对命中明确非音乐特征或超长/极短时长的条目做剔除与降权，不误伤纯音乐源；
/// 2. 当首次搜索明显被非音乐噪声淹没时，提示调用方自动补发音乐意图关键词检索并合并重排；
/// 3. 永远保留保底结果（若全部条目都被剔除，则回退为按得分排序的原始结果，避免搜出真空列表）。
enum SearchResultFilter {

    struct Assessment: Sendable, Equatable {
        let refined: [Track]
        let cleanMusicCount: Int
        let noisyCount: Int
        let needsMusicIntentSupplement: Bool
    }

    static let minimumSingleDuration: TimeInterval = 25
    static let maximumSingleDuration: TimeInterval = 660 // 11 分钟：兼容较长 Live/摇滚，挡住常见长视频
    static let idealMinimumDuration: TimeInterval = 90
    static let idealMaximumDuration: TimeInterval = 420

    /// 强非音乐词：除非用户搜索词本身包含该词，否则视为非音乐视频并剔除。
    private static let hardBlockedKeywords: [String] = [
        // 直播录像
        "直播回放", "直播录像", "全程录像", "整场录像", "录屏回放",
        // 游戏实况 / 攻略 / 热门游戏名
        "实况", "通关", "攻略", "新手村", "上分", "开黑", "速通",
        "配队", "光锥", "命途", "超击破", "深渊", "遗器", "圣遗物",
        "全收集", "全结局", "多结局", "隐藏结局", "真结局", "结局",
        "副本", "boss战", "屠杀", "满级",
        "原神", "崩坏星穹铁道", "星穹铁道", "星铁", "绝区零", "鸣潮",
        "王者荣耀", "英雄联盟", "使命召唤", "我的世界", "minecraft",
        "黑神话", "艾尔登法环", "塞尔达", "博德之门", "生化危机", "gta",
        "超级马里奥", "马里奥制造", "任天堂", "switch",
        "宅男的人间冒险", "恐怖游戏", "游戏解说", "单机游戏",
        // 影视 / 动漫杂谈 / 访谈 / 科普 / 搞笑整活 / 有声读物
        "阅片无数", "动漫篇", "动漫杂谈", "新番吐槽", "影视解说", "电影解说",
        "剧情解析", "解说", "影评", "一口气看完", "带你看完", "分钟看完",
        "爽文", "简史", "人物志", "科普", "历史", "讲故事",
        "有声书", "有声小说", "广播剧", "听书", "评书", "脱口秀",
        "采访现场", "专访", "采访", "访谈", "vlog", "开箱", "测评", "评测",
        "鬼畜调教", "鬼畜全明星", "鬼畜", "整活", "沙雕", "搞笑", "吐槽", "相声", "小品",
        "reaction", "tutorial", "walkthrough", "gameplay", "playthrough",
    ]

    /// 轻度降权词：可能仍是音频但通常不是用户搜歌的首选（注意不误伤"录音棚"）。
    private static let demotedKeywords: [String] = [
        "教程", "教学", "讲解", "乐理", "谱例", "指法",
        "鼓谱", "琴谱", "动态鼓谱", "简谱", "五线谱", "架子鼓",
        "花絮", "幕后", "合集", "串烧", "歌单", "盘点", "带你听完",
        "伴奏", "纯伴奏", "消音", "混剪", "amv", "mad", "翻车", "名场面",
        "bgm合集", "高燃混剪",
    ]

    /// 明确正向音乐特征词（命中标题即视为正向音乐信号）。
    private static let musicBoostKeywords: [String] = [
        "mv", "m/v", "official", "官方", "完整版", "纯享", "无损",
        "hi-res", "hires", "flac", "live", "现场", "演唱会", "音乐节",
        "翻唱", "cover", "单曲", "歌曲", "原唱", "音源", "歌词",
        "动态歌词", "专辑", "录音室", "录音棚", "主题曲", "片尾曲",
        "片头曲", "插曲", "ost", "纯音", "合唱", "独唱", "清唱",
        "音乐", "乐队", "试听", "电台", "music", "audio", "song",
    ]

    /// 投稿账号名里的音乐频道特征词（如 `ISTE-音乐小铺`、`LRS-LeoFM`、`华纳音乐`）。
    private static let musicChannelKeywords: [String] = [
        "音乐", "唱片", "乐队", "电台", "fm", "music", "audio", "records", "studio", "live", "歌单", "音悦",
    ]

    /// 用户搜索词本身已带有音乐意图限定时，不再重复补搜。
    private static let explicitMusicIntentTerms: [String] = [
        "歌曲", "音乐", "mv", "live", "现场", "翻唱", "cover", "纯享",
        "无损", "hi-res", "hires", "伴奏", "歌词", "完整版", "原唱",
        "ost", "主题曲", "片尾曲", "插曲", "song", "music", "audio",
    ]

    /// 用户显式搜合集/长音频时不按单曲时长上限截断。
    private static let longFormIntentTerms: [String] = [
        "合集", "串烧", "歌单", "整场", "演唱会", "全程", "联唱",
        "交响", "组曲", "播客", "电台", "mix", "playlist", "album", "live set",
    ]

    /// 生成自动补搜的音乐意图查询词（按优先级排序；若存在权威曲库目录，额外追加热门歌手定向检索）。
    static func supplementQueries(for rawQuery: String,
                                  catalogEntries: [MusicCatalogEntry] = []) -> [String] {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let lower = TextNormalizer.simplified(trimmed).lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.contains("://") {
            return []
        }
        if trimmed.range(of: #"^(?i)bv[0-9a-z]{10}$"#, options: .regularExpression) != nil {
            return []
        }
        if explicitMusicIntentTerms.contains(where: { lower.contains($0) }) {
            return []
        }
        let hasCJK = trimmed.unicodeScalars.contains {
            (0x3400...0x9FFF).contains($0.value) || (0x3040...0x30FF).contains($0.value)
        }
        var queries: [String] = []
        // 若权威目录已给出热门歌手（如搜「十年」→「十年 陈奕迅」），优先用定向歌手补搜，减少无效请求。
        for targeted in MusicCatalogResolver.topArtistSupplementQueries(for: trimmed, entries: catalogEntries, limit: 2)
        where !queries.contains(targeted) {
            queries.append(targeted)
        }
        let genericQuery = hasCJK ? "\(trimmed) 歌曲" : "\(trimmed) song"
        if !queries.contains(genericQuery) {
            queries.append(genericQuery)
        }
        let mvQuery = "\(trimmed) MV"
        if !queries.contains(mvQuery) {
            queries.append(mvQuery)
        }
        return queries
    }

    /// 评估原始搜索结果质量，并输出过滤、去重、重排后的曲目列表。
    /// 当传入权威歌曲目录 `catalogEntries`（来自已导入的正规音乐插件如 QQ 音乐，或 iTunes 公开曲库）时，
    /// 命中正规 `(歌名 + 歌手 + 时长)` 的条目直接获得超高置信度并置顶。
    static func assess(_ tracks: [Track],
                       query: String,
                       isVideoPlatformSource: Bool = false,
                       catalogEntries: [MusicCatalogEntry] = []) -> Assessment {
        guard !tracks.isEmpty else {
            return Assessment(refined: [], cleanMusicCount: 0, noisyCount: 0, needsMusicIntentSupplement: false)
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerQuery = TextNormalizer.simplified(trimmedQuery).lowercased()
        let normalizedQuery = LyricQueryNormalizer.normalize(trimmedQuery)
        let queryTokens = tokenizeQuery(trimmedQuery)
        let allowLongForm = longFormIntentTerms.contains { lowerQuery.contains($0) }

        var noisyCount = 0
        var cleanMusicCount = 0
        var strongMusicCount = 0
        var verifiedOriginalCount = 0
        var strongMusicItems: [(track: Track, score: Int, index: Int)] = []
        var kept: [(track: Track, score: Int, index: Int)] = []
        var allScored: [(track: Track, score: Int, index: Int)] = []

        for (index, track) in tracks.enumerated() {
            let evaluation = evaluate(
                track: track,
                lowerQuery: lowerQuery,
                normalizedQuery: normalizedQuery,
                queryTokens: queryTokens,
                allowLongForm: allowLongForm,
                catalogEntries: catalogEntries
            )
            allScored.append((track, evaluation.score, index))
            if evaluation.isNoisy {
                noisyCount += 1
            } else {
                kept.append((track, evaluation.score, index))
                if evaluation.isCleanMusic {
                    cleanMusicCount += 1
                }
                if evaluation.hasStrongMusicEvidence {
                    strongMusicCount += 1
                    strongMusicItems.append((track, evaluation.score, index))
                }
                if evaluation.isVerifiedOriginal {
                    verifiedOriginalCount += 1
                }
            }
        }

        // 若全部结果都是干净音乐且未触发任何噪声拦截，保留原插件顺序（避免打乱纯音乐源的官方排序）。
        let ordered: [Track]
        if noisyCount == 0 && !isVideoPlatformSource && catalogEntries.isEmpty {
            ordered = deduplicate(tracks)
        } else {
            // 视频站源：只要已经凑齐 ≥ 4 首具明确音乐证据的真歌，就清退完全没有音乐证据的泛视频（如情感/VLOG/日常）。
            let pool: [(track: Track, score: Int, index: Int)]
            if isVideoPlatformSource && strongMusicItems.count >= 4 {
                pool = strongMusicItems
            } else if !kept.isEmpty {
                pool = kept
            } else {
                pool = allScored
            }
            let sorted = pool.sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.index < rhs.index
            }.map(\.track)
            ordered = deduplicate(sorted)
        }

        // 触发自动音乐意图补搜的条件：
        // 1. 明显命中黑名单/超长噪声污染；
        // 2. 视频站源即使未撞黑名单，只要绝大多数条目缺乏明确音乐证据（如搜《十年》《演员》返回满屏 Vlog/情感短片），
        //    也主动补搜「关键词 歌曲」/ 权威热门歌手定向词 /「关键词 MV」。
        let noiseRatio = Double(noisyCount) / Double(max(tracks.count, 1))
        let strongRatio = Double(strongMusicCount) / Double(max(tracks.count, 1))
        let polluted = noisyCount >= 2 && (noiseRatio >= 0.35 || cleanMusicCount < 4)
        let singleNoisyHit = noisyCount == tracks.count && tracks.count >= 1
        let videoSourceStarved = isVideoPlatformSource && (
            (cleanMusicCount < 3 && noisyCount >= 1)
                || (tracks.count >= 2 && strongMusicCount < 5 && strongRatio < 0.45)
        )
        // 若权威目录已明确热门原唱（如搜「十年」→ 陈奕迅），但视频源首轮几乎全是 AI 翻唱或无关短视频、原唱不足 2 首，也触发定向补搜。
        let catalogNeedsOriginalSupplement = isVideoPlatformSource
            && !catalogEntries.isEmpty
            && verifiedOriginalCount < 2
            && !MusicCatalogResolver.topArtistSupplementQueries(for: trimmedQuery, entries: catalogEntries, limit: 2).isEmpty
        let needsSupplement = !supplementQueries(for: trimmedQuery, catalogEntries: catalogEntries).isEmpty
            && (polluted || singleNoisyHit || videoSourceStarved || catalogNeedsOriginalSupplement)

        return Assessment(
            refined: ordered,
            cleanMusicCount: isVideoPlatformSource ? strongMusicCount : cleanMusicCount,
            noisyCount: noisyCount,
            needsMusicIntentSupplement: needsSupplement
        )
    }

    static func refine(_ tracks: [Track],
                       query: String,
                       isVideoPlatformSource: Bool = false,
                       catalogEntries: [MusicCatalogEntry] = []) -> [Track] {
        assess(tracks, query: query, isVideoPlatformSource: isVideoPlatformSource, catalogEntries: catalogEntries).refined
    }

    /// 聚合多源搜索结果的轻量稳定重排：不删除任何合法条目，仅让高相关歌曲排到前排，
    /// 避免慢一点但精准命中的源被先返回但低相关的源压到下面。
    static func rankAggregated(_ tracks: [Track], query: String) -> [Track] {
        guard tracks.count > 1 else { return tracks }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return tracks }
        let lowerQuery = TextNormalizer.simplified(trimmedQuery).lowercased()
        let normalizedQuery = LyricQueryNormalizer.normalize(trimmedQuery)
        let queryTokens = tokenizeQuery(trimmedQuery)
        let allowLongForm = longFormIntentTerms.contains { lowerQuery.contains($0) }

        return tracks.enumerated()
            .map { index, track in
                let eval = evaluate(
                    track: track,
                    lowerQuery: lowerQuery,
                    normalizedQuery: normalizedQuery,
                    queryTokens: queryTokens,
                    allowLongForm: allowLongForm
                )
                return (track: track, score: eval.score, index: index)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.index < rhs.index
            }
            .map(\.track)
    }

    /// 判断数据源是否属于视频投稿类插件（用于识别噪声与保护隐式歌手不可信）。
    static func isLikelyVideoSource(sourceID: SourceID, displayName: String = "", allowedDomains: [String] = []) -> Bool {
        let bag = [sourceID.rawValue, displayName].joined(separator: " ").lowercased()
        let tokens = ["bili", "b站", "哔哩", "youtube", "ytb", "acfun", "douyin", "tiktok", "niconico"]
        if tokens.contains(where: { bag.contains($0) }) {
            return true
        }
        return allowedDomains.contains { domain in
            let d = domain.lowercased()
            return d.contains("bilibili.com") || d.contains("bilivideo.") || d.contains("youtube.com") || d.contains("youtu.be")
        }
    }

    // MARK: - 内部评分与去重

    private struct ItemEvaluation {
        let isNoisy: Bool
        let isCleanMusic: Bool
        let hasStrongMusicEvidence: Bool
        let isVerifiedOriginal: Bool
        let score: Int
    }

    private static func evaluate(track: Track,
                                 lowerQuery: String,
                                 normalizedQuery: String,
                                 queryTokens: [String],
                                 allowLongForm: Bool,
                                 catalogEntries: [MusicCatalogEntry] = []) -> ItemEvaluation {
        let lowerTitle = TextNormalizer.simplified(track.title.precomposedStringWithCompatibilityMapping).lowercased()
        let lowerArtist = TextNormalizer.simplified(track.artist.precomposedStringWithCompatibilityMapping).lowercased()
        let combined = lowerTitle + " " + lowerArtist

        let hasHardBlocked = hardBlockedKeywords.contains { word in
            !lowerQuery.contains(word) && combined.contains(word)
        }
        let demoteHits = demotedKeywords.filter { word in
            !lowerQuery.contains(word) && lowerTitle.contains(word)
        }.count
        let musicHits = musicBoostKeywords.filter { word in
            lowerTitle.contains(word)
        }.count

        let tooShort = track.duration > 0 && track.duration < minimumSingleDuration
        let tooLong = !allowLongForm && track.duration > maximumSingleDuration
        // 含明确电影/剧集剧情词（如"直击电影《...》"、"男主角/女主角"）且无任何音乐特征词
        let nonMusicDramaCue = !lowerQuery.contains("电影")
            && (lowerTitle.contains("直击电影") || lowerTitle.contains("电影《") || lowerTitle.contains("电视剧《"))
            && musicHits == 0

        let isNoisy = hasHardBlocked || tooShort || tooLong || nonMusicDramaCue

        var score = 0
        if hasHardBlocked { score -= 25 }
        if tooLong { score -= 18 }
        if tooShort { score -= 12 }
        if nonMusicDramaCue { score -= 15 }
        score -= demoteHits * 4
        score += min(musicHits, 3) * 4

        // 常见单曲黄金时长区间加分
        if track.duration >= idealMinimumDuration && track.duration <= idealMaximumDuration {
            score += 4
        } else if track.duration >= minimumSingleDuration && track.duration <= maximumSingleDuration {
            score += 1
        }

        // 标题与搜索词相关性打分（支持单关键词与「歌手 歌名」多词组合）
        let parsed = LyricQueryNormalizer.parseTitle(track.title)
        let normParsedTitle = LyricQueryNormalizer.normalize(parsed.title)
        let normParsedArtist = parsed.artist.map { LyricQueryNormalizer.normalize($0) } ?? ""
        let normFullTitle = LyricQueryNormalizer.normalize(track.title)
        let normCombined = normFullTitle + " " + LyricQueryNormalizer.normalize(track.artist)
        var titleRelevance = 0

        if !normalizedQuery.isEmpty {
            if normParsedTitle == normalizedQuery || lowerTitle.contains("《\(lowerQuery)》") || lowerTitle.contains("「\(lowerQuery)」") {
                titleRelevance = 12
            } else if hasStandaloneMatch(normalizedQuery, in: lowerTitle) {
                titleRelevance = 8
            } else if queryTokens.count >= 2 {
                // 多词检索（如「马里奥 主角」「周杰伦 晴天」）：逐词检查，避免因中间隔"的"或顺序不同被判 0 分。
                let hitCount = queryTokens.filter { token in
                    normCombined.contains(token)
                        || normParsedTitle == token
                        || normParsedArtist == token
                }.count
                if hitCount == queryTokens.count {
                    let hasCoreTitleMatch = queryTokens.contains { token in
                        normParsedTitle == token
                            || lowerTitle.contains("《\(token)》")
                            || lowerTitle.contains("「\(token)」")
                            || hasStandaloneMatch(token, in: lowerTitle)
                    }
                    titleRelevance = hasCoreTitleMatch ? 14 : 9
                } else if hitCount > 0 {
                    titleRelevance = hitCount * 3
                }
            } else if normFullTitle.contains(normalizedQuery) {
                // 只是复合词的一部分（如搜"主角"命中"男主角"/"女主角"/"爽文主角"）
                let embeddedOnly = isOnlyEmbeddedInCompound(normalizedQuery, in: lowerTitle)
                titleRelevance = embeddedOnly ? -3 : 4
            }
        }
        score += titleRelevance

        // 有明确「歌手 - 歌名」或书名号结构，通常是正经音乐投稿
        let hasStructuredTitle = parsed.artist != nil
            || (!nonMusicDramaCue && (lowerTitle.contains("《") || lowerTitle.contains("「") || lowerTitle.contains("『")))
        let isMusicChannel = musicChannelKeywords.contains { lowerArtist.contains($0) }
        if hasStructuredTitle {
            score += 3
        }
        if isMusicChannel {
            score += 3
        }

        // 权威歌曲目录交叉校验（QQ 音乐等已导入正规插件 / Apple iTunes 公开曲库）：
        // 视频标题同时命中权威曲库的 `(歌名 + 歌手)` 且时长合理时，直接确认为高置信真歌。
        var catalogBonus = 0
        if !catalogEntries.isEmpty && !isNoisy {
            for entry in catalogEntries {
                let s = MusicCatalogResolver.matchScore(
                    trackTitle: track.title,
                    trackArtist: track.artist,
                    trackDuration: track.duration,
                    against: entry
                )
                if s > catalogBonus { catalogBonus = s }
            }
        }
        score += catalogBonus

        // AI 翻唱 / 唱K 跟唱 / 业余翻唱轻度降权（用户未显式搜索 AI/翻唱时），让原唱/官方/无损自然排在前面。
        let isAICover = !lowerQuery.contains("ai") && isAICoverTitle(lowerTitle)
        let isCoverOrKaraoke = !lowerQuery.contains("翻唱")
            && !lowerQuery.contains("cover")
            && !lowerQuery.contains("唱k")
            && (lowerTitle.contains("翻唱") || lowerTitle.contains("cover") || lowerTitle.contains("唱k") || lowerTitle.contains("跟唱"))
        if isAICover {
            score -= 8
        } else if isCoverOrKaraoke {
            score -= 3
        }

        // 零相关防御：搜索词完全未出现在标题/歌手中且未命中权威目录（如 B 站拆字召回的文不对题翻唱）大幅降权且不计入强音乐证据。
        let isZeroRelevance = !normalizedQuery.isEmpty && titleRelevance == 0 && catalogBonus == 0
        if isZeroRelevance {
            score -= 12
        }

        let hasStrongMusicEvidence = !isNoisy
            && !isZeroRelevance
            && demoteHits == 0
            && (catalogBonus > 0 || musicHits > 0 || hasStructuredTitle || isMusicChannel)
        let isCleanMusic = !isNoisy
            && !isZeroRelevance
            && demoteHits == 0
            && (hasStrongMusicEvidence || titleRelevance >= 8 || (track.duration >= idealMinimumDuration && track.duration <= idealMaximumDuration))
        let isVerifiedOriginal = !isNoisy
            && !isZeroRelevance
            && demoteHits == 0
            && !isAICover
            && !isCoverOrKaraoke
            && catalogBonus > 0

        return ItemEvaluation(
            isNoisy: isNoisy,
            isCleanMusic: isCleanMusic,
            hasStrongMusicEvidence: hasStrongMusicEvidence,
            isVerifiedOriginal: isVerifiedOriginal,
            score: score
        )
    }

    /// 识别「【AI林俊杰】」「【AI偶像】」「AI翻唱」「AI歌手」等 AI 换声二创标题。
    private static func isAICoverTitle(_ lowerTitle: String) -> Bool {
        if lowerTitle.contains("ai翻唱")
            || lowerTitle.contains("ai合成")
            || lowerTitle.contains("ai歌手")
            || lowerTitle.contains("ai偶像")
            || lowerTitle.contains("ai版")
            || lowerTitle.contains("【ai")
            || lowerTitle.contains("[ai") {
            return true
        }
        return lowerTitle.range(of: #"(?:^|[\s（(])ai[\u4e00-\u9fff]{2,4}"#, options: .regularExpression) != nil
    }

    private static func tokenizeQuery(_ raw: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "-－—/·|｜《》「」"))
        return raw.components(separatedBy: separators)
            .map { LyricQueryNormalizer.normalize($0) }
            .filter { !$0.isEmpty }
    }

    /// 检查 `token` 是否以非汉字紧邻粘连的方式独立出现（例如「林俊杰 - 主角」「主角 MV」），
    /// 区别于「男主角」「女主角」「爽文主角」这类纯复合词误命中。
    private static func hasStandaloneMatch(_ token: String, in lowerTitle: String) -> Bool {
        guard !token.isEmpty else { return false }
        let scalars = Array(lowerTitle)
        let target = Array(token)
        guard target.count <= scalars.count else { return false }
        let cjkToken = target.allSatisfy(isCJK)
        for start in 0...(scalars.count - target.count) {
            if Array(scalars[start..<(start + target.count)]) == target {
                let prev = start > 0 ? scalars[start - 1] : nil
                let next = (start + target.count) < scalars.count ? scalars[start + target.count] : nil
                if cjkToken {
                    let prevBoundary = prev.map { !isCJK($0) } ?? true
                    let nextBoundary = next.map { !isCJK($0) } ?? true
                    if prevBoundary && nextBoundary { return true }
                } else {
                    let prevBoundary = prev.map { !($0.isLetter || $0.isNumber) } ?? true
                    let nextBoundary = next.map { !($0.isLetter || $0.isNumber) } ?? true
                    if prevBoundary && nextBoundary { return true }
                }
            }
        }
        return false
    }

    private static func isOnlyEmbeddedInCompound(_ token: String, in lowerTitle: String) -> Bool {
        guard token.count >= 2, token.allSatisfy(isCJK) else { return false }
        return !hasStandaloneMatch(token, in: lowerTitle)
    }

    private static func isCJK(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        return (0x4E00...0x9FFF).contains(scalar.value)
            || (0x3400...0x4DBF).contains(scalar.value)
            || (0x3041...0x30FA).contains(scalar.value)
    }

    private static func deduplicate(_ tracks: [Track]) -> [Track] {
        var seenIdentities = Set<TrackIdentity>()
        var result: [Track] = []
        result.reserveCapacity(tracks.count)
        for track in tracks where seenIdentities.insert(track.identity).inserted {
            result.append(track)
        }
        return result
    }
}
