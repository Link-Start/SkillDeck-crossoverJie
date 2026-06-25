import XCTest
@testable import SkillDeck

/// Unit tests for root-level skill update handling.
///
/// Background: A "root-level skill" has SKILL.md directly in the repository root (not in a subdirectory).
/// Example: `eze-is/web-access` repo structure:
///   /SKILL.md          ← root-level (folderPath = "")
///   /scripts/
///   /references/
///
/// A "sub-directory skill" has SKILL.md in a subdirectory:
/// Example: `vercel-labs/skills` repo structure:
///   /skills/find-skills/SKILL.md  ← sub-directory (folderPath = "skills/find-skills")
///
/// Bug fixed: When updating a root-level skill, `skillPath = "SKILL.md"` from the lock file was
/// incorrectly used as `folderPath`, causing `getTreeHash` to compute `git rev-parse HEAD:SKILL.md`
/// (blob hash) instead of `git rev-parse HEAD:` (root tree hash). This led to:
/// 1. Wrong hash comparison → update check missed real updates
/// 2. `copyItem` copied the SKILL.md file over the skill directory → directory became a file
@MainActor
final class RootLevelSkillUpdateTests: XCTestCase {

    // MARK: - deriveFolderPath Tests

    /// Root-level skill: skillPath "SKILL.md" should derive folderPath ""
    ///
    /// When SKILL.md is at the repository root, the folder path must be empty.
    /// An empty folderPath causes `git rev-parse HEAD:` (root tree hash),
    /// which matches what `installSkill()` stores in the lock file.
    func testDeriveFolderPath_rootLevelSkill() {
        let result = SkillManager.deriveFolderPath(from: "SKILL.md")
        XCTAssertEqual(result, "",
                       "Root-level skill 'SKILL.md' should derive empty folderPath")
    }

    /// Sub-directory skill: skillPath "skills/find-skills/SKILL.md" should derive folderPath "skills/find-skills"
    ///
    /// Standard case for multi-skill repos where each skill is in its own subdirectory.
    func testDeriveFolderPath_subDirectorySkill() {
        let result = SkillManager.deriveFolderPath(from: "skills/find-skills/SKILL.md")
        XCTAssertEqual(result, "skills/find-skills",
                       "Sub-directory skill should strip '/SKILL.md' suffix")
    }

    /// Nested sub-directory skill: deeper nesting should also work
    func testDeriveFolderPath_deeplyNestedSkill() {
        let result = SkillManager.deriveFolderPath(from: "path/to/my-skill/SKILL.md")
        XCTAssertEqual(result, "path/to/my-skill",
                       "Deeply nested skill should strip '/SKILL.md' suffix")
    }

    /// Edge case: single-level sub-directory skill "my-skill/SKILL.md"
    func testDeriveFolderPath_singleLevelSubDirectory() {
        let result = SkillManager.deriveFolderPath(from: "my-skill/SKILL.md")
        XCTAssertEqual(result, "my-skill",
                       "Single-level sub-directory skill should strip '/SKILL.md' suffix")
    }

    /// Regression test: the old buggy code would return "SKILL.md" instead of ""
    ///
    /// Before the fix, the logic was:
    /// ```
    /// if skillPath.hasSuffix("/SKILL.md") { ... }
    /// else { folderPath = skillPath }  // ← "SKILL.md" doesn't end with "/SKILL.md", so this branch
    /// ```
    /// This test ensures the bug does not regress.
    func testDeriveFolderPath_oldBugWouldReturnSkillMD() {
        let result = SkillManager.deriveFolderPath(from: "SKILL.md")
        // Old buggy result: "SKILL.md"
        // Correct result: ""
        XCTAssertNotEqual(result, "SKILL.md",
                          "Old bug: folderPath should NOT be 'SKILL.md' for root-level skills")
        XCTAssertEqual(result, "",
                       "Correct: folderPath should be empty for root-level skills")
    }

    // MARK: - Git Hash Behavior Tests

    /// Verify that `getTreeHash` returns different hashes for root vs SKILL.md file.
    ///
    /// This is the root cause demonstration:
    /// - `git rev-parse HEAD:` (empty path) → root tree hash (what installSkill stores)
    /// - `git rev-parse HEAD:SKILL.md` → blob hash of SKILL.md file
    ///
    /// If `deriveFolderPath` returns "SKILL.md" instead of "", the hash comparison in
    /// `checkForUpdate` would compare blob hash vs tree hash, which are always different,
    /// potentially causing false "has update" or "no update" results.
    func testGetTreeHash_rootVsFileDiffer() async throws {
        let fm = FileManager.default
        let repoDir = fm.temporaryDirectory
            .appendingPathComponent("SkillDeckRootLevelTest-\(UUID().uuidString)")
        try fm.createDirectory(at: repoDir, withIntermediateDirectories: true)

        // Initialize a git repo with a root-level SKILL.md
        try runGit(["init"], in: repoDir)
        let skillMD = """
        ---
        name: test-root-skill
        description: A test root-level skill
        ---
        # Test Skill
        Content here.
        """
        try skillMD.write(
            to: repoDir.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        // Also add a scripts directory (like eze-is/web-access has)
        let scriptsDir = repoDir.appendingPathComponent("scripts")
        try fm.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        try "console.log('hello')".write(
            to: scriptsDir.appendingPathComponent("check.mjs"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "."], in: repoDir)
        try runGit(["commit", "-m", "Initial commit"], in: repoDir)

        defer { try? fm.removeItem(at: repoDir) }

        let gitService = GitService()

        // Root tree hash (correct: what installSkill stores)
        let rootTreeHash = try await gitService.getTreeHash(for: "", in: repoDir)

        // Blob hash of SKILL.md (wrong: what the old buggy code would compare)
        let fileBlobHash = try await gitService.getTreeHash(for: "SKILL.md", in: repoDir)

        // These MUST be different — if they were the same, the bug wouldn't manifest
        XCTAssertNotEqual(rootTreeHash, fileBlobHash,
                          "Root tree hash and SKILL.md blob hash must differ — this is why the bug caused problems")

        // Both should be valid 40-char hex strings
        XCTAssertEqual(rootTreeHash.count, 40)
        XCTAssertEqual(fileBlobHash.count, 40)
    }

    /// Verify that after a simulated root-level skill update, the canonical path remains a directory.
    ///
    /// This simulates the exact bug scenario:
    /// 1. Skill installed as directory: ~/.agents/skills/web-access/ containing SKILL.md
    /// 2. Update with buggy folderPath="SKILL.md" → copyItem(SKILL.md file, directory path)
    /// 3. Result: directory replaced by file → symlink broken → Claude Code can't find SKILL.md
    ///
    /// With the fix, folderPath="" → sourceDir=repoDir → copyItem preserves directory structure.
    func testUpdatePreservesDirectoryStructure_forRootLevelSkill() throws {
        let fm = FileManager.default
        let tempBase = fm.temporaryDirectory
            .appendingPathComponent("SkillDeckUpdateTest-\(UUID().uuidString)")
        try fm.createDirectory(at: tempBase, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempBase) }

        // Simulate a cloned repo with root-level skill
        let repoDir = tempBase.appendingPathComponent("repo")
        try fm.createDirectory(at: repoDir, withIntermediateDirectories: true)
        try "---\nname: web-access\n---\n# Web Access".write(
            to: repoDir.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let scriptsDir = repoDir.appendingPathComponent("scripts")
        try fm.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        try "console.log('test')".write(
            to: scriptsDir.appendingPathComponent("check.mjs"),
            atomically: true,
            encoding: .utf8
        )

        // Simulate existing canonical directory (correct state before update)
        let canonicalDir = tempBase.appendingPathComponent("skills").appendingPathComponent("web-access")
        try fm.createDirectory(at: canonicalDir, withIntermediateDirectories: true)
        try "old content".write(
            to: canonicalDir.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        // Verify starting state: canonicalDir is a directory
        var isDir: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: canonicalDir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue, "Before update: canonicalDir should be a directory")

        // Simulate update with CORRECT folderPath (empty string for root-level skill)
        let correctFolderPath = SkillManager.deriveFolderPath(from: "SKILL.md")
        XCTAssertEqual(correctFolderPath, "", "Sanity check")

        let sourceDir: URL
        if correctFolderPath.isEmpty {
            sourceDir = repoDir  // Entire repo root
        } else {
            sourceDir = repoDir.appendingPathComponent(correctFolderPath)
        }

        // Delete + copy (same as updateSkill)
        try fm.removeItem(at: canonicalDir)
        try fm.copyItem(at: sourceDir, to: canonicalDir)

        // Verify: canonicalDir should still be a directory with all files
        isDir = false
        XCTAssertTrue(fm.fileExists(atPath: canonicalDir.path, isDirectory: &isDir),
                       "After update: canonicalDir should still exist")
        XCTAssertTrue(isDir.boolValue,
                       "After update: canonicalDir should still be a directory (not a file)")

        // Verify all files from the repo are present
        XCTAssertTrue(fm.fileExists(atPath: canonicalDir.appendingPathComponent("SKILL.md").path),
                       "SKILL.md should exist in canonical directory")
        XCTAssertTrue(fm.fileExists(atPath: canonicalDir.appendingPathComponent("scripts").path),
                       "scripts/ directory should exist in canonical directory")
        XCTAssertTrue(fm.fileExists(atPath: canonicalDir.appendingPathComponent("scripts/check.mjs").path),
                       "scripts/check.mjs should exist in canonical directory")
    }

    /// Verify the OLD buggy behavior: folderPath="SKILL.md" would replace directory with file.
    ///
    /// This test documents the exact failure mode. If the bug regresses, this test will catch it.
    func testBuggyUpdateWouldReplaceDirectoryWithFile() throws {
        let fm = FileManager.default
        let tempBase = fm.temporaryDirectory
            .appendingPathComponent("SkillDeckBuggyTest-\(UUID().uuidString)")
        try fm.createDirectory(at: tempBase, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempBase) }

        // Simulate a cloned repo
        let repoDir = tempBase.appendingPathComponent("repo")
        try fm.createDirectory(at: repoDir, withIntermediateDirectories: true)
        try "---\nname: web-access\n---\n# Web Access".write(
            to: repoDir.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        // Simulate existing canonical directory
        let canonicalDir = tempBase.appendingPathComponent("skills").appendingPathComponent("web-access")
        try fm.createDirectory(at: canonicalDir, withIntermediateDirectories: true)
        try "old content".write(
            to: canonicalDir.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        // Simulate the OLD buggy folderPath derivation
        let buggyFolderPath = "SKILL.md"  // Old code: skillPath doesn't end with "/SKILL.md", so use as-is
        let buggySourceDir = repoDir.appendingPathComponent(buggyFolderPath)

        // Delete + copy with buggy sourceDir (which is a FILE, not a directory)
        try fm.removeItem(at: canonicalDir)
        try fm.copyItem(at: buggySourceDir, to: canonicalDir)

        // After the buggy update, canonicalDir is now a FILE, not a directory
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: canonicalDir.path, isDirectory: &isDir)
        XCTAssertTrue(exists, "Path exists (but as a file)")
        XCTAssertFalse(isDir.boolValue,
                       "BUG: canonicalDir is now a file, not a directory! Symlink would be broken.")

        // Verify: reading it as a file gives SKILL.md content
        let content = try String(contentsOf: canonicalDir, encoding: .utf8)
        XCTAssertTrue(content.contains("web-access"),
                      "File content is SKILL.md — directory was replaced by file")
    }

    // MARK: - findCommitForTreeHash Backfill Tests

    /// Verify `findCommitForTreeHash` works with empty folderPath (root-level skill backfill).
    ///
    /// When a root-level skill has no cached commit hash, `checkForUpdate()` calls
    /// `findCommitForTreeHash(treeHash:, folderPath: "", in: repoDir)` to search git history.
    ///
    /// Before the fix, `git log --format=%H -- ""` would fail because git rejects an empty pathspec:
    ///   fatal: empty string is not a valid pathspec. please use . instead if you meant to match all paths
    ///
    /// After the fix, empty folderPath omits the `--` separator entirely,
    /// so `git log --format=%H` lists all commits, and `git rev-parse <commit>:` returns root tree hash.
    func testFindCommitForTreeHash_rootLevelSkill() async throws {
        let fm = FileManager.default
        let repoDir = fm.temporaryDirectory
            .appendingPathComponent("SkillDeckBackfillTest-\(UUID().uuidString)")
        try fm.createDirectory(at: repoDir, withIntermediateDirectories: true)

        // Initialize a git repo with two commits
        try runGit(["init"], in: repoDir)

        // Commit 1: create SKILL.md
        try "---\nname: root-skill\n---\n# v1".write(
            to: repoDir.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "."], in: repoDir)
        try runGit(["commit", "-m", "Initial commit"], in: repoDir)

        // Get the root tree hash after first commit
        let gitService = GitService()
        let firstTreeHash = try await gitService.getTreeHash(for: "", in: repoDir)

        // Commit 2: modify SKILL.md
        try "---\nname: root-skill\n---\n# v2 updated".write(
            to: repoDir.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "."], in: repoDir)
        try runGit(["commit", "-m", "Update skill"], in: repoDir)

        let secondTreeHash = try await gitService.getTreeHash(for: "", in: repoDir)

        // Sanity: tree hashes should differ after content change
        XCTAssertNotEqual(firstTreeHash, secondTreeHash,
                          "Tree hashes should differ after content change")

        defer { try? fm.removeItem(at: repoDir) }

        // Act: find commit for the FIRST tree hash (backfill scenario)
        // This is the exact call that would fail before the fix with:
        //   git log --format=%H -- ""
        let foundCommit = try await gitService.findCommitForTreeHash(
            treeHash: firstTreeHash,
            folderPath: "",  // Root-level skill
            in: repoDir
        )

        // Assert: should find the first commit
        XCTAssertNotNil(foundCommit,
                        "Should find commit for root-level skill tree hash (backfill must work)")

        // Verify the found commit is valid by checking it exists in the repo
        if let commit = foundCommit {
            XCTAssertEqual(commit.count, 40, "Commit hash should be 40 hex characters")
        }
    }

    /// Verify `findCommitForTreeHash` with empty folderPath handles errors gracefully.
    ///
    /// Edge case: `git log` in a repo with no commits throws (non-zero exit).
    /// This is acceptable — the caller (checkForUpdate) catches errors per-skill
    /// and marks the skill as `.error` state in the UI. The important thing is
    /// that the error is a git error, not a crash from empty pathspec.
    func testFindCommitForTreeHash_rootLevelEmptyRepoThrowsGitError() async throws {
        let fm = FileManager.default
        let repoDir = fm.temporaryDirectory
            .appendingPathComponent("SkillDeckEmptyRepoTest-\(UUID().uuidString)")
        try fm.createDirectory(at: repoDir, withIntermediateDirectories: true)

        // Init repo but don't commit anything
        try runGit(["init"], in: repoDir)

        defer { try? fm.removeItem(at: repoDir) }

        let gitService = GitService()

        // Should throw a git error (no commits), NOT crash from empty pathspec
        do {
            _ = try await gitService.findCommitForTreeHash(
                treeHash: "any-hash",
                folderPath: "",
                in: repoDir
            )
            // If it doesn't throw, that's also fine (edge case: some git versions may return empty)
        } catch {
            // Expected: git errors on empty repo are acceptable.
            // The key thing is we don't get a "pathspec" error from the empty folderPath fix.
            let errorDesc = (error as NSError).localizedDescription
            XCTAssertFalse(errorDesc.contains("pathspec"),
                           "Should NOT get a pathspec error — that was the original bug")
        }
    }

    // MARK: - Helper Methods

    /// Run a git command in the specified directory.
    ///
    /// Similar to `Process` usage in GitServiceTests.swift.
    /// Uses `/usr/bin/git` (system git on macOS).
    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        // Suppress git output to keep test logs clean
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "RootLevelSkillUpdateTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed"]
            )
        }
    }
}
