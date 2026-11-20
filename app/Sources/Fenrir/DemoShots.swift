import AppKit
import Foundation

/// `FENRIR_SELFTEST=demo`: README screenshots from neutral demo projects. Run it with `HOME` and
/// `FENRIR_HOME` pointing at a throwaway directory; it creates `~/code/demo-*` there. Needs FENRIR_SHOTS_DIR.
@MainActor
enum DemoShots {
    private static func write(_ path: String, _ text: String) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    static func run(_ model: AppModel) async {
        let env = ProcessInfo.processInfo.environment
        let dir = env["FENRIR_SHOTS_DIR"] ?? NSTemporaryDirectory() + "fenrir-shots"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let code = NSHomeDirectory() + "/code"
        let api = code + "/demo-api", web = code + "/demo-web", docs = code + "/demo-docs"
        write(api + "/README.md", "# demo-api\n\nA small HTTP service used to try Fenrir.\n\n## Run\n\n```sh\nmake run\n```\n\n- `GET /health` returns `ok`\n- `GET /items` lists items\n")
        write(api + "/src/main.rs", "use std::net::TcpListener;\n\nfn main() {\n    // bind the demo port and serve /health and /items\n    let listener = TcpListener::bind(\"127.0.0.1:8080\").unwrap();\n    println!(\"listening on {}\", listener.local_addr().unwrap());\n}\n")
        write(api + "/src/routes.rs", "pub fn health() -> &'static str { \"ok\" }\n")
        write(api + "/tests/health.rs", "#[test]\nfn health_is_ok() {\n    assert_eq!(demo_api::routes::health(), \"ok\");\n}\n")
        write(api + "/Cargo.toml", "[package]\nname = \"demo-api\"\nversion = \"0.1.0\"\nedition = \"2021\"\n")
        write(api + "/Makefile", "run:\n\tcargo run\n")
        write(api + "/.harness/HANDOFF.md", "# Handoff\n\n- Health route done and tested\n- Next: pagination for `/items`\n")
        write(web + "/package.json", "{\n  \"name\": \"demo-web\",\n  \"version\": \"0.1.0\"\n}\n")
        write(web + "/src/index.ts", "export const title = \"Demo\";\n")
        write(docs + "/guide.md", "# Guide\n\nNotes for the demo.\n")
        for p in [api, web, docs] {
            let name = (p as NSString).lastPathComponent
            model.add(name: name, path: p, host: nil)
        }
        await SelfTest.pause(2)
        let apiP = model.projects.first { $0.name == "demo-api" }!
        let webP = model.projects.first { $0.name == "demo-web" }!
        let docsP = model.projects.first { $0.name == "demo-docs" }!
        model.newSession(in: apiP)
        await SelfTest.pause(2)
        func ev(_ kind: EventKind, _ p: Project, _ msg: String? = nil) {
            let s = model.sessions(of: p).first!
            model.handle(HookEvent(kind: kind, cwd: p.path, claudeSession: "demo", fenrirSession: s.id, projectId: p.id,
                                   message: msg, tsMs: Int64(Date().timeIntervalSince1970 * 1000) - 130_000, agentId: nil, agentType: nil, agents: nil, title: nil, prompt: nil, ordinal: nil, tmuxSession: nil))
        }
        ev(.working, apiP)
        ev(.idle, webP)
        ev(.needsInput, docsP, "Claude needs your permission to use Bash")
        model.select(sessionID: model.sessions(of: apiP).first!.id)
        let id = model.selectedSessionID!
        SelfTest.type(model, id, "export PS1='demo-api $ '; clear\n")
        await SelfTest.pause(1)
        SelfTest.type(model, id, "clear; printf 'running 2 tests\\ntest routes::health_is_ok ... ok\\ntest items::lists_all ... ok\\n\\ntest result: ok. 2 passed; 0 failed\\n'; ls\n")
        await SelfTest.pause(1.5)
        model.panelTab = .files
        await SelfTest.pause(1.5)
        Screenshots.snapshot(dir + "/main-window.png")
        model.openFile(path: api + "/src/main.rs", host: nil)
        await SelfTest.pause(1.5)
        Screenshots.snapshot(dir + "/file-tab.png")
    }
}
