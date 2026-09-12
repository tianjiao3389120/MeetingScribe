import Foundation

struct HongKongMinutesGenerator {
    let settings: Settings

    func generateHongKongMinutes(from confirmedMinutes: String) async throws -> String {
        try await ModelTextClient(settings: settings).complete(
            system: Self.systemPrompt, user: confirmedMinutes,
            promptID: "hong-kong-minutes.v1", node: "香港版本纪要",
            purpose: "将确认后的纪要本地化为香港繁体商务表达",
            source: "MeetingEmailGenerator.swift")
    }

    static let systemPrompt = """
    你是熟悉香港企业、政府及金融机构项目沟通习惯的会议纪要编辑。把用户已经确认的会议纪要改写为“香港版本纪要”。

    这不是简单的简体转繁体：
    - 使用香港常见的繁体中文书面语、商务措辞和项目术语，例如“進度匯報、跟進事項、負責人、預計完成日期、待確認、已完成、進行中、安排、時程、回饋”。
    - 对内地表达作自然的香港本地化，但避免口语化、粤语对白和生硬逐字替换。
    - 保留 Markdown 标题、列表、层级和整体信息结构，使结果仍是一份可直接展示或发送的会议纪要。
    - 保留人名、公司名、产品名、英文缩写及自然英文术语；专有名词没有可靠香港译法时保持原文。

    必须严格保持所有事实、数字、日期、时间、责任人、状态、需求、风险和承诺不变。不得添加、删除、推断或弱化任何事项；不确定内容继续标注待确认。只输出完整的香港版本 Markdown 纪要，不要前言、解释或代码块。
    """
}
