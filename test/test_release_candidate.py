from __future__ import annotations

import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("release_candidate", ROOT / "script/release_candidate.py")
assert SPEC is not None and SPEC.loader is not None
release_candidate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release_candidate)


class ReleaseCandidateUnitTest(unittest.TestCase):
    def test_tag_identity_is_annotated_and_independent_of_current_head(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory)
            subprocess.run(["git", "init", "-q"], cwd=repository, check=True)
            subprocess.run(["git", "config", "user.name", "Candidate Test"], cwd=repository, check=True)
            subprocess.run(["git", "config", "user.email", "candidate@example.invalid"], cwd=repository, check=True)
            (repository / "candidate.txt").write_text("candidate\n", encoding="utf-8")
            subprocess.run(["git", "add", "candidate.txt"], cwd=repository, check=True)
            subprocess.run(["git", "commit", "-qm", "candidate C"], cwd=repository, check=True)
            candidate_commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repository, text=True).strip()
            subprocess.run(
                ["git", "tag", "-a", release_candidate.CANDIDATE_TAG, "-m", "candidate"],
                cwd=repository,
                check=True,
            )
            (repository / "evidence.txt").write_text("evidence\n", encoding="utf-8")
            subprocess.run(["git", "add", "evidence.txt"], cwd=repository, check=True)
            subprocess.run(["git", "commit", "-qm", "evidence E"], cwd=repository, check=True)
            evidence_head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repository, text=True).strip()

            previous_repo = release_candidate.REPO
            try:
                release_candidate.REPO = repository
                identity = release_candidate.resolve_candidate_tag(release_candidate.CANDIDATE_TAG)
            finally:
                release_candidate.REPO = previous_repo

            self.assertEqual(identity["candidateCommit"], candidate_commit)
            self.assertNotEqual(identity["candidateCommit"], evidence_head)
            self.assertEqual(identity["tagType"], "annotated")

    def test_candidate_scope_is_fail_closed(self) -> None:
        scope = release_candidate.read_json(ROOT / "release/v1.2/candidate-scope.json")
        release_candidate.validate_candidate_scope(scope)
        self.assertFalse(scope["release"]["mainnetAuthorized"])
        self.assertEqual(
            [item["id"] for item in scope["excludedMainnetApplications"]],
            ["src20-market", "seth", "auction"],
        )

    def test_duplicate_json_members_are_rejected(self) -> None:
        with self.assertRaisesRegex(release_candidate.CandidateError, "duplicate JSON member"):
            release_candidate.strict_json_bytes(b'{"scope":1,"\\u0073cope":2}', "fixture.json")

    def test_forbidden_paths_fail_closed(self) -> None:
        scope = release_candidate.read_json(ROOT / "release/v1.2/source-scope.json")
        release_candidate.validate_source_scope(scope)
        for path in ["wallet.txt", ".env.local", "services/x/private.key", "out/Contract.json", "apps/x/node_modules/y.js"]:
            self.assertTrue(release_candidate.is_forbidden_path(path, scope), path)
        self.assertFalse(release_candidate.is_forbidden_path("services/svm-indexer/.env.example", scope))
        self.assertEqual(
            scope["excludedExact"],
            [
                "release/v1.2/candidate.json",
                "release/v1.2/source-files.sha256",
                "security-results/stage7m-s7b002.json",
                "security-results/stage7m-multiseed.json",
                "security-results/stage7m-base-mainnet-fork.json",
            ],
        )

    def test_source_hash_parser_rejects_duplicates_and_bad_lines(self) -> None:
        digest = "a" * 64
        with self.assertRaisesRegex(release_candidate.CandidateError, "duplicate source hash path"):
            release_candidate.parse_source_lines(f"{digest}  src/A.sol\n{digest}  src/A.sol\n".encode())
        with self.assertRaisesRegex(release_candidate.CandidateError, "malformed source hash line"):
            release_candidate.parse_source_lines(b"not-a-hash  src/A.sol\n")

    def test_candidate_integrity_rejects_mutation(self) -> None:
        scope = release_candidate.read_json(ROOT / "release/v1.2/candidate-scope.json")
        source_control = {
            "candidateTag": release_candidate.CANDIDATE_TAG,
            "tagStatus": "frozen",
            "tagObject": "1" * 40,
            "tagType": "annotated",
            "candidateCommit": "2" * 40,
            "candidateTree": "3" * 40,
        }
        commitments = {
            "scopeSha256": "4" * 64,
            "sourceListSha256": "5" * 64,
            "sourceFileCount": 1,
            "artifactInventorySha256": "6" * 64,
            "toolchainSha256": "7" * 64,
            "submodulesSha256": "8" * 64,
            "specSha256": "9" * 64,
            "isaKeccak256": "0x" + "a" * 64,
        }
        candidate = release_candidate.build_candidate(scope, source_control, commitments)
        release_candidate.validate_candidate_integrity(candidate)
        self.assertNotIn("headCommit", candidate["sourceControl"])
        self.assertNotIn("treeState", candidate["sourceControl"])
        changed = json.loads(json.dumps(candidate))
        changed["release"]["mainnetAuthorized"] = True
        with self.assertRaisesRegex(release_candidate.CandidateError, "report hash mismatch"):
            release_candidate.validate_candidate_integrity(changed)

    def test_candidate_schema_fields_match_generator(self) -> None:
        scope = release_candidate.read_json(ROOT / "release/v1.2/candidate-scope.json")
        schema = release_candidate.read_json(ROOT / "release/v1.2/schema/release-candidate-v1.schema.json")
        candidate = release_candidate.build_candidate(
            scope,
            {
                "candidateTag": release_candidate.CANDIDATE_TAG,
                "tagStatus": "frozen",
                "tagObject": "1" * 40,
                "tagType": "annotated",
                "candidateCommit": "2" * 40,
                "candidateTree": "3" * 40,
            },
            {
                "scopeSha256": "4" * 64,
                "sourceListSha256": "5" * 64,
                "sourceFileCount": 1,
                "artifactInventorySha256": "6" * 64,
                "toolchainSha256": "7" * 64,
                "submodulesSha256": "8" * 64,
                "specSha256": "9" * 64,
                "isaKeccak256": "0x" + "a" * 64,
            },
        )
        self.assertEqual(set(candidate), set(schema["required"]))
        for field in ["release", "sourceControl", "scope", "commitments", "verification", "signature", "integrity"]:
            self.assertEqual(set(candidate[field]), set(schema["properties"][field]["required"]), field)

    def test_secret_scanner_does_not_echo_secret_content(self) -> None:
        with tempfile.TemporaryDirectory(dir=ROOT) as directory:
            target = Path(directory) / "candidate-secret.txt"
            marker = "-----BEGIN " + "PRIVATE KEY-----"
            target.write_text(f"{marker}\nsecret material\n", encoding="utf-8")
            relative = target.relative_to(ROOT).as_posix()
            scope = release_candidate.read_json(ROOT / "release/v1.2/source-scope.json")
            with self.assertRaisesRegex(release_candidate.CandidateError, "matched content intentionally omitted"):
                release_candidate.scan_secrets([relative], scope, lambda path: (ROOT / path).read_bytes())


if __name__ == "__main__":
    unittest.main()
