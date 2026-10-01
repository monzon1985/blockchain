# SPDX-License-Identifier: MIT
import json

from perps_sim import gen_paths
from perps_sim.paths import WAD


def test_committed_fixtures_are_up_to_date():
    assert gen_paths.check_all(gen_paths.DEFAULT_OUT) == []


def test_fixture_schema():
    for spec in gen_paths.SPECS:
        doc = json.loads((gen_paths.DEFAULT_OUT / f"{spec.name}.json").read_text(encoding="utf-8"))
        assert set(doc) == {"name", "model", "seed", "params", "dtSeconds", "prices"}
        assert doc["name"] == spec.name
        assert doc["dtSeconds"] == spec.dt_seconds
        assert len(doc["prices"]) == spec.steps + 1
        assert all(isinstance(p, str) and int(p) > 0 for p in doc["prices"])
        assert int(doc["prices"][0]) == int(spec.s0) * WAD


def test_scenarios_have_their_intended_character():
    def ret(name):
        doc = gen_paths.fixture(next(s for s in gen_paths.SPECS if s.name == name))
        return int(doc["prices"][-1]) / int(doc["prices"][0]) - 1

    assert ret("gbm_rally") > 0.05
    assert ret("gbm_selloff") < -0.05
    assert ret("merton_squeeze") > 0.3
    assert ret("merton_crash") < -0.1


def test_check_detects_tampering_missing_and_extra(tmp_path):
    gen_paths.write_all(tmp_path)
    assert gen_paths.check_all(tmp_path) == []

    target = tmp_path / "gbm_calm.json"
    doc = json.loads(target.read_text(encoding="utf-8"))
    doc["prices"][5] = str(int(doc["prices"][5]) + 1)
    target.write_text(json.dumps(doc), encoding="utf-8")
    (tmp_path / "gbm_volatile.json").unlink()
    (tmp_path / "rogue.json").write_text("{}", encoding="utf-8")

    problems = gen_paths.check_all(tmp_path)
    assert any("stale fixture gbm_calm.json" in p and "prices" in p for p in problems)
    assert any("missing fixture gbm_volatile.json" in p for p in problems)
    assert any("unexpected fixture rogue.json" in p for p in problems)


def test_check_ignores_line_endings(tmp_path):
    gen_paths.write_all(tmp_path)
    for path in tmp_path.glob("*.json"):
        path.write_bytes(path.read_bytes().replace(b"\n", b"\r\n"))
    assert gen_paths.check_all(tmp_path) == []


def test_cli_exit_codes(tmp_path, capsys):
    assert gen_paths.main(["--out", str(tmp_path)]) == 0
    assert gen_paths.main(["--check", "--out", str(tmp_path)]) == 0
    (tmp_path / "gbm_calm.json").unlink()
    assert gen_paths.main(["--check", "--out", str(tmp_path)]) == 1
    assert "missing fixture" in capsys.readouterr().err
