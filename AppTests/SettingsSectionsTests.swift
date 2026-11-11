import XCTest
@testable import AnimalTracker

final class SettingsSectionsTests: XCTestCase {
    func testLocalOnlyHidesAccountAndOralCheckIn() {
        XCTAssertEqual(SettingsSections.visible(localOnly: true), [.animals, .tags, .data, .about])
    }

    func testFullBuildShowsEverySectionInOrder() {
        XCTAssertEqual(SettingsSections.visible(localOnly: false), SettingsSection.allCases)
    }

    func testLocalOnlyAboutFootnoteSaysRecordsStayOnThePhoneAndAreInTheDeviceBackup() {
        XCTAssertEqual(SettingsSections.aboutFootnote(localOnly: true),
                       "Animals, voice recordings and tags stay on this phone and are not synced to any account. Your phone's own iCloud or computer backup includes them.")
    }

    func testFullBuildAboutFootnoteKeepsTheSyncText() {
        XCTAssertEqual(SettingsSections.aboutFootnote(localOnly: false),
                       "Animals, voice recordings and tags sync to your Supabase account. Oral check-in transcripts are sent to Anthropic, using your own key.")
    }
}
