//
//  CPYUpdatesPreferenceViewController.swift
//
//  Clipy
//  GitHub: https://github.com/clipy
//  HP: https://clipy-app.com
//
//  Created by Econa77 on 2016/03/17.
//
//  Copyright © 2015-2018 Clipy Project.
//

import Cocoa

class CPYUpdatesPreferenceViewController: NSViewController {

    @IBOutlet private weak var lastUpdateCheckDateTextField: NSTextField!
    @IBOutlet private weak var versionTextField: NSTextField!

    override func loadView() {
        super.loadView()
        lastUpdateCheckDateTextField.formatter = nil
        if let date = UserDefaults.standard.object(forKey: ClipyMeReleaseUpdates.lastSuccessKey) as? Date {
            lastUpdateCheckDateTextField.stringValue = "Last checked: " + date.formatted(date: .abbreviated, time: .shortened)
        } else {
            lastUpdateCheckDateTextField.stringValue = "Updates from khandelwaly940/clipy.me"
        }
        versionTextField.stringValue = "v\(Bundle.main.appVersion ?? "")"
    }

    @IBAction private func checkForUpdates(_ sender: Any) {
        (NSApp.delegate as? AppDelegate)?.releaseUpdates.check(manual: true)
    }
}
