import Foundation

struct MeetingEmailGenerator {
    enum Tone: String, CaseIterable, Identifiable {
        case formal = "正式"
        case natural = "自然"
        case concise = "简洁"
        var id: String { rawValue }
    }

    enum Audience: String, CaseIterable, Identifiable {
        case customer = "客户"
        case internalTeam = "内部同事"
        case partner = "合作伙伴"
        var id: String { rawValue }
    }

    let settings: Settings

    func generateChinese(title: String, workspaceName: String?, minutes: String,
                         template: EmailTemplate, tone: Tone,
                         audience: Audience) async throws -> String {
        try await complete(system: Self.chineseSystemPrompt(
            template: template, tone: tone, audience: audience),
                           user: "会议名称：\(title)\n客户或项目：\(workspaceName ?? "未提供")\n\n已确认的会议纪要：\n\(minutes)")
    }

    func generateHongKongTraditional(from confirmedChinese: String) async throws -> String {
        try await complete(system: Self.hongKongSystemPrompt, user: confirmedChinese)
    }

    static func chineseSystemPrompt(template: EmailTemplate = .general,
                                    tone: Tone, audience: Audience) -> String {
        """
        你是阶段性工作同步邮件编辑。根据会议纪要起草一封面向\(audience.rawValue)的简体中文邮件，语气\(tone.rawValue)。
        第一行是“主题：【客户或项目】符合本邮件模板的简短主题”；仅当输入明确提供日期范围时才加日期范围。

        Hi All,

        以下是[客户或项目]本周期的工作进度同步：

        本次使用“\(template.name)”模板，严格遵守下面的结构要求：
        \(template.instructions)

        结尾保持简短，不虚构签名。
        只使用纪要中的事实；不确定的信息标注“待确认”；不要虚构收件人、日期范围、负责人、完成比例或承诺。
        保留 HIDS、SIEM、Agent、Hotfix、UAT、DMP、CVE、Hash 等自然英文业务术语，不做生硬翻译。
        输出可直接复制的纯文本邮件，不要 Markdown 表格、Markdown 代码块、前言或解释。
        """
    }

    static let hongKongSystemPrompt = """
    你是香港商务邮件编辑。把用户已经确认的简体中文邮件改写为香港常用繁体中文商务表达。
    必须保持“整体总结、问题与故障、需求”的结构，以及主题、事实、数字、日期、责任人、待办和段落含义不变；保留人名、公司名、产品名、缩写和自然的英文业务术语。
    使用香港项目工作邮件常见措辞，例如“進度匯報、已閉環、進行中、待更新、待業務回饋、時程”，但不要为了套用措辞改变事实。
    这不是重新总结会议，不得增加或删除承诺。只输出可直接复制的纯文本邮件，不要解释。
    """

    private func complete(system: String, user: String) async throws -> String {
        try await ModelTextClient(settings: settings).complete(system: system, user: user)
    }
}
