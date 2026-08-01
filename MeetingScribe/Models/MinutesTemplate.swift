import Foundation

struct MinutesTemplate: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let instructions: String

    static let general = MinutesTemplate(
        id: "general", name: "通用会议",
        instructions: "完整整理议题、结论、决定、待办、责任人和截止时间。")
    static let customer = MinutesTemplate(
        id: "customer", name: "客户沟通",
        instructions: "重点整理客户问题、明确需求、承诺事项、分歧、风险和下一步跟进。")
    static let biweekly = MinutesTemplate(
        id: "biweekly", name: "双周会",
        instructions: "按进展、问题与风险、决定、下阶段计划和责任人整理，并关注上期事项的延续。")
    static let review = MinutesTemplate(
        id: "review", name: "项目评审",
        instructions: "重点整理评审对象、评审意见、通过或不通过的决定、修改项、负责人和验收条件。")
    static let incident = MinutesTemplate(
        id: "incident", name: "故障复盘",
        instructions: "按影响、时间线、根因、处置过程、有效与无效措施、改进项和责任人整理。")
    static let requirements = MinutesTemplate(
        id: "requirements", name: "需求讨论",
        instructions: "重点整理业务目标、用户场景、范围边界、验收标准、待确认问题和优先级。")

    static let all = [general, customer, biweekly, review, incident, requirements]
    static func template(id: String?) -> MinutesTemplate {
        all.first { $0.id == id } ?? general
    }
}
