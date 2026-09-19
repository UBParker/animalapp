import Foundation

enum PressKind: String, Codable, CaseIterable { case prompted, spontaneous }
enum FeedCategory: String, Codable, CaseIterable { case forage, food, supplement, treat }
enum CheckInStatus: String, Codable, CaseIterable { case inProgress, reviewed, saved, discarded, failed }
enum TurnRole: String, Codable, CaseIterable { case user, assistant }
enum VoiceStatus: String, Codable, CaseIterable { case recorded, analyzed, noSounds, failed }
enum VoiceTagKind: String, Codable, CaseIterable { case activity, meaning }
