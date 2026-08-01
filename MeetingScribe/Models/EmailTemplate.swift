import Foundation

struct EmailTemplate: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let instructions: String

    static let general = EmailTemplate(
        id: "general-follow-up", name: "通用会议跟进",
        instructions: "按沟通摘要、已确认结论、待办事项、责任人、时程和待确认问题组织正文。")
    static let customer = EmailTemplate(
        id: "customer-follow-up", name: "客户沟通跟进",
        instructions: "按本次沟通摘要、客户关注事项、已确认结论、双方待办、待确认问题和下一次跟进安排组织正文。")
    static let progress = EmailTemplate(
        id: "progress-update", name: "阶段性工作同步",
        instructions: """
        沿用阶段性项目进度汇报结构：
        一、整体总结：概括总体进展、已闭环事项、当前最重要风险和下一步重点。
        二、问题与故障：每项使用“序号. 问题名称（当前状态）”，再按实际信息整理现象与影响、根因、方案、验证、下一步。
        三、需求：逐项列出需求、状态和时程；没有明确时程写“待确认”，没有需求写“本期无新增需求”。
        """)
    static let review = EmailTemplate(
        id: "review-result", name: "评审结果通知",
        instructions: "按评审结论、已通过事项、需要修改的内容、验收条件、负责人和完成时间组织正文。")
    static let incident = EmailTemplate(
        id: "incident-review", name: "故障复盘同步",
        instructions: "按故障摘要与影响、时间线、根因、处置过程、恢复情况、改进措施和责任人组织正文。")
    static let requirements = EmailTemplate(
        id: "requirements-confirmation", name: "需求确认邮件",
        instructions: "按需求背景、已确认范围、本期范围外内容、验收标准、优先级与计划、待确认问题组织正文。")

    static let all = [general, customer, progress, review, incident, requirements]

    static func template(id: String?) -> EmailTemplate {
        all.first { $0.id == id } ?? general
    }

    static func defaultID(forMinutesTemplateID id: String?) -> String {
        switch MinutesTemplate.template(id: id).id {
        case MinutesTemplate.customer.id: return customer.id
        case MinutesTemplate.biweekly.id: return progress.id
        case MinutesTemplate.review.id: return review.id
        case MinutesTemplate.incident.id: return incident.id
        case MinutesTemplate.requirements.id: return requirements.id
        default: return general.id
        }
    }
}
