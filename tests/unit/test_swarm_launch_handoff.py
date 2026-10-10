"""Launch-receipt handoff through the actual Bash/Python CLI."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from herdr_socket_stub import HerdrStub, agent_row  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
LAUNCH = ROOT / "scripts/lib/swarm_launch.sh"
PACKET = ROOT / "scripts/lib/swarm_packet.sh"
ASSIGN = ROOT / "scripts/lib/swarm_assign.sh"
HELPER = ROOT / "scripts/lib/herdr_agents.sh"

PROBE = r'''#!/usr/bin/env python3
import hashlib, json, os, pathlib, sys
root = pathlib.Path(os.environ["HANDOFF_ROOT"])
name, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
mode = os.environ.get("HANDOFF_MODE", "ok")
assert pathlib.Path.cwd() == root / "repo"
with (root / "calls").open("a") as f:
    f.write(json.dumps([name, args]) + "\n")
def flag(key):
    return args[args.index(key) + 1]
if name == "plan":
    n = int(flag("--agents"))
    print(json.dumps({"schema_version":1,"status":"pass","exit_code":0,
        "requested_agents":n,"workload":flag("--workload"),"safe_agents":32,"recommended_agents":32,
        "quiesce_advisory":{"recommendation":"proceed"},"recommendation":"launch",
        "checks":[{"id":"capacity","status":"pass"}]}))
elif name == "ntm":
    raise AssertionError("delivery goes through herdr's socket, never ntm")
elif name == "am":
    assert args[:2] in (["agents","create"], ["agents","list"]) and flag("--project") == str(root / "repo")
    count = root / "am-count"
    n = int(count.read_text()) if count.exists() else 0
    if args[:2] == ["agents","list"]:
        print(json.dumps([{"name":x} for x in ["GreenCastle","AmberFox","CopperHill"][:n]])); sys.exit(0)
    count.write_text(str(n + 1))
    print(json.dumps({"name":["GreenCastle","AmberFox","CopperHill"][n]}))
elif name == "herdr":
    sp = root / "herdr-state.json"
    st = json.loads(sp.read_text()) if sp.exists() else {"workspaces":[],"agents":[],"labels":{},"next":2}
    def save(): sp.write_text(json.dumps(st))
    def ok(result): print(json.dumps({"result":result})); sys.exit(0)
    if args[:2] == ["status","server"]:
        print("server:\n  status: running"); sys.exit(0)
    if args[:2] == ["workspace","list"]:
        ok({"workspaces":st["workspaces"]})
    if args[:2] == ["workspace","create"]:
        assert (root / "launch.json").is_file()
        st["workspaces"].append({"workspace_id":"w9","label":flag("--label")}); save()
        ok({"workspace":{"workspace_id":"w9"}})
    if args[:2] == ["tab","create"]:
        n = st["next"]; st["next"] += 1
        st["labels"]["w9:t%d" % n] = flag("--label"); save()
        ok({"tab":{"tab_id":"w9:t%d" % n},"root_pane":{"pane_id":"w9:p%d" % n}})
    if args[:2] == ["tab","list"]:
        ok({"tabs":[{"tab_id":t,"label":l,"workspace_id":"w9"} for t,l in st["labels"].items()]})
    if args[:2] == ["agent","start"]:
        pane = flag("--pane"); n = int(pane.rsplit(":p",1)[1])
        st["agents"].append({"workspace_id":"w9","tab_id":"w9:t%d" % n,"pane_id":pane,"name":args[2],
            "agent":flag("--kind"),"agent_status":"idle","cwd":str(root / "repo"),"terminal_id":"term_%d" % n})
        save()
        (root / "spawned").write_text("yes")
        if mode == "lost-spawn-reply" and n == 3:
            print(json.dumps({"error":{"code":"server_error","message":"lost"}}),file=sys.stderr); sys.exit(1)
        ok({"agent":{"name":args[2]}})
    changed = (mode == "server-changed" or (mode == "change-during" and (root / "prepared-called").exists()))
    if args[:2] == ["agent","list"]:
        rows = [] if mode == "missing-pane" else [dict(a) for a in st["agents"]]
        for a in rows:
            if changed or (mode == "change-after-first" and a["pane_id"] == "w9:p3" and (root / "sends").exists()):
                a["terminal_id"] += "x"
            if mode == "wrong-repo": a["cwd"] = str(root)
        ok({"agents":rows})
    if args[:2] == ["pane","process-info"]:
        pane = flag("--pane"); n = int(pane.rsplit(":p",1)[1])
        kind = next(a["agent"] for a in st["agents"] if a["pane_id"] == pane)
        shown = "bash" if mode == "shell" else kind
        pid = (2000 if mode == "pane-replaced" else 1000) + n
        ok({"process_info":{"pane_id":pane,"shell_pid":pid,"foreground_processes":[{"name":shown,"pid":pid+1}]}})
    raise AssertionError(args)
elif name == "br":
    assert args == ["ready","--json"], args
    print((root / "beads.json").read_text())
elif name == "packet":
    assert args[0] == "--prepare-batch" and "--send" not in args
    output = pathlib.Path(args[1])
    assert flag("--repo") == str(root / "repo") and flag("--workspace") == "w9" and "--session" not in args
    assert "--no-live-context" in args
    received = {key: json.loads(pathlib.Path(flag(key)).read_text()) for key in
        ("--scopes-file","--assignments","--ready-file","--triage-file","--beads-file") if key in args}
    targets = [args[i+1] for i,a in enumerate(args) if a == "--target"]
    (root / "preparation-inputs").write_text(json.dumps({"targets":targets,"sources":received}))
    (root / "prepared-called").write_text("yes")
    if mode == "preparation-failed":
        print("private failure",file=sys.stderr); print('{"schema":"acfs.packet-delivery.v2","status":"error"}'); sys.exit(2)
    if mode == "no-work":
        print(json.dumps({"schema":"acfs.packet-preparation.v1","status":"no_work","delivery_count":0,
            "sends_prompt":False,"directory_created":False,"idle_targets":targets})); sys.exit(1)
    output.mkdir(mode=0o700)
    (output / "batch.json").write_text("{}")
    print(json.dumps({"schema":"acfs.packet-preparation.v1","status":"prepared","directory":str(output),
        "delivery_count":len(targets),"sends_prompt":False,
        "preview_command":"acfs swarm packet --deliver-batch " + str(output / "batch.json")}))
else:
    raise AssertionError(name)
'''


# Stands in for swarm_packet.sh --deliver: it writes the same create-only intent
# and <receipt>.result.json that the real deliverer writes around herdr's
# agent.prompt, and logs each prompt that reached a pane in `sends`.
DISPATCH_PACKET = r'''#!/usr/bin/env python3
import hashlib, json, os, pathlib, sys
root = pathlib.Path(os.environ["HANDOFF_ROOT"])
args = sys.argv[1:]
mode = os.environ.get("HANDOFF_MODE", "ok")
assert pathlib.Path.cwd() == root / "repo"
with (root / "calls").open("a") as f: f.write(json.dumps(["packet",args]) + "\n")
def enc(v): return (json.dumps(v,sort_keys=True,ensure_ascii=True,indent=2) + "\n").encode()
def digest(b): return hashlib.sha256(b).hexdigest()
def flag(k): return args[args.index(k)+1]
def request(item, parent):
    path = (parent / item["packet"]).absolute()
    raw = path.read_bytes()
    packet = json.loads(raw)
    assert packet["schema_version"] == 1 and packet["output"]["truncated"] is False
    payload = packet["packet_markdown"].encode()
    assert payload.startswith(b"# ACFS Swarm Startup Packet\n")
    r = {"repo":str((parent/item["repo"]).absolute()),"workspace":item["workspace"],"pane_id":item["pane_id"],
         "agent_type":item["agent_type"],"operation_id":item["operation_id"],"bead_id":packet["bead"]["id"],
         "packet_sha256":digest(raw),"payload_sha256":digest(payload),"payload_bytes":len(payload)}
    return r, path, (parent/item["receipt"]).absolute(), payload
def publish(path, value):
    fd = os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(fd,"wb") as f:
        f.write(enc(value)); f.flush(); os.fsync(f.fileno())
def fail():
    print('{"schema":"acfs.packet-delivery.v2","status":"error"}'); sys.exit(2)
try:
    if args[0] == "--deliver-batch":
        assert "--send" not in args
        path = pathlib.Path(args[1]); raw = path.read_bytes(); batch = json.loads(raw)
        details, reviewed = [], []
        for item in batch["deliveries"]:
            r, packet, receipt, payload = request(item,path.parent)
            if receipt.exists():
                saved = json.loads(receipt.read_text())
                assert saved["schema"] == "acfs.packet-delivery.v2" and saved["request"] == r
            details.append({"schema":"acfs.packet-delivery.v2","status":"preview","request":r,
                "receipt":str(receipt),"sends_prompt":False,"send_command":"unguarded command must not escape"})
            reviewed.append({"request":r,"packet":str(packet),"receipt":str(receipt)})
        review = {"schema":batch["schema"],"manifest_sha256":digest(raw),"deliveries":reviewed}
        print(json.dumps({"schema":batch["schema"],"status":"preview","sends_prompt":False,
            "manifest_sha256":digest(raw),"review_sha256":digest(enc(review)),"deliveries":details}))
        if mode == "mutate-after-preview":
            item = batch["deliveries"][-1]; path = path.parent/item["packet"]
            value = json.loads(path.read_text()); value["packet_markdown"] += "changed"
            path.write_text(json.dumps(value))
        if mode == "remove-intent-after-preview":
            # Simulate external removal without deleting user work: move it aside.
            for item in batch["deliveries"]:
                receipt = pathlib.Path(args[1]).parent/item["receipt"]
                if receipt.exists(): receipt.rename(str(receipt) + ".retained")
        sys.exit(0)
    assert args[0] == "--deliver" and "--send" in args
    item = {k:flag("--"+k.replace("_","-")) for k in
            ("repo","workspace","pane_id","agent_type","operation_id","receipt")}
    item["packet"] = args[1]
    r, packet, receipt, payload = request(item,pathlib.Path.cwd())
    assert flag("--expect-sha256") == r["packet_sha256"]
    assert r["workspace"] == "w9" and r["agent_type"] == ("codex" if r["pane_id"] == "w9:p2" else "claude"), r
    # A recovery request must never call this send-capable path.
    assert not receipt.exists() and not pathlib.Path(str(receipt) + ".result.json").exists()
    terminal = "term_" + r["pane_id"].rsplit(":p",1)[1]
    publish(receipt,{"schema":"acfs.packet-delivery.v2","request":r,"target":terminal,"agent_session":None})
    op = r["operation_id"]
    if mode == "refused-first" and op == "work-1":
        status, evidence = "refused", {"error_code":"agent_blocked"}
    else:
        with (root / "sends").open("a") as f: f.write(json.dumps([r["pane_id"],op]) + "\n")
        (root / ("payload-" + op)).write_bytes(payload)
        status, evidence = ("unconfirmed", {}) if mode == "lost-first" and op == "work-1" else \
            ("submitted", {"pane_id":r["pane_id"],"terminal_id":terminal,"workspace_id":"w9"})
    if status != "unconfirmed":
        publish(str(receipt) + ".result.json",{"schema":"acfs.packet-delivery.v2","request":r,"target":terminal,
            "status":status,"evidence":evidence})
    if mode == "bad-child-response": print("[]"); sys.exit(0)
    print(json.dumps({"schema":"acfs.packet-delivery.v2","status":status,"evidence":evidence,
        "request":r,"receipt":str(receipt),"sends_prompt":status != "refused","reconciled_only":False,
        "agent_execution_verified":False}))
    sys.exit(0 if status == "submitted" else 1)
except (AssertionError, KeyError, ValueError, OSError):
    fail()
'''


class HandoffTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="acfs-receipt-handoff-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(os.path.realpath(self.temp.name))
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.lib = self.root / "lib"
        self.lib.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        if Path("/usr/bin/python3").is_file():
            (self.bin / "python3").symlink_to("/usr/bin/python3")
        self.script = self.lib / "swarm_launch.sh"
        shutil.copyfile(LAUNCH, self.script)
        shutil.copyfile(HELPER, self.lib / "herdr_agents.sh")
        for name in ("ntm","herdr","am","plan","packet"):
            path = self.bin / name
            path.write_text(PROBE)
            path.chmod(0o755)
        for kind, name in (("plan","swarm_plan.sh"),("packet","swarm_packet.sh")):
            (self.lib / name).write_text('#!/bin/bash\nexec ' + shlex.quote(str(self.bin / kind)) + ' "$@"\n')
        # Spawning Codex needs its app-server daemon running without HERDR_*
        # variables (acfs-gen.3). Fake a clean one, so the host's real codex
        # and daemon are never touched, and a codex that fails if called.
        codex_home, proc = self.root / "codex-home", self.root / "proc"
        (codex_home / "app-server-daemon").mkdir(parents=True)
        (codex_home / "app-server-daemon" / "daemon.pid").write_text('{"pid":777}\n')
        (proc / "777").mkdir(parents=True)
        (proc / "777" / "cmdline").write_bytes(b"codex\0app-server\0daemon\0")
        (proc / "777" / "environ").write_bytes(b"PATH=/usr/bin\0")
        (self.bin / "codex").write_text("#!/bin/sh\nexit 97\n")
        (self.bin / "codex").chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin)+os.pathsep+os.environ["PATH"], HANDOFF_ROOT=str(self.root),
                        ACFS_HOME=str(self.root / "no-acfs-home"), CODEX_HOME=str(codex_home),
                        HERDR_AGENTS_PROC_ROOT=str(proc))
        self.env.pop("HERDR_WORKSPACE_ID", None)
        self.receipt = self.root / "launch.json"
        self.output = self.root / "work bundle"
        self.scopes = self.root / "scopes.json"
        self.scopes.write_text('{"schema_version":1,"scopes":{"bd-api":["src/api/**"],"bd-doc":["docs/**"]}}')
        self.assignments = self.root / "assignments.json"
        self.assignments.write_text(json.dumps({"assignments":[{"slot":2}]}))
        self.launch_args = ["--repo",str(self.repo),"--session","project","--receipt",str(self.receipt),
                            "--agent","CodeSlot:codex","--agent","ReviewSlot:claude"]

    def invoke(self, args, mode="ok"):
        result = subprocess.run(["bash",str(self.script),*args], cwd=self.root,
            env=dict(self.env,HANDOFF_MODE=mode), capture_output=True,text=True,timeout=25)
        self.assertEqual(result.stderr,"",result.stderr)
        return result.returncode, json.loads(result.stdout)

    def launch(self):
        code, preview = self.invoke(self.launch_args)
        self.assertEqual(code,0,preview)
        code, result = self.invoke([*self.launch_args,"--expect-sha256",preview["review_sha256"],"--launch"])
        self.assertEqual((code,result["status"]),(0,"ready"),result)
        return result

    def handoff(self, mode="ok", identities=None, saved=False, extra=()):
        args = ["--prepare-batch",str(self.output),"--receipt",str(self.receipt),"--no-live-context"]
        args += ["--assignments",str(self.assignments)] if saved else ["--scopes-file",str(self.scopes)]
        for value in identities or ("2:RedFox","1:BlueLake"):
            args += ["--identity",value]
        return self.invoke([*args,*extra],mode)

    def calls(self):
        path = self.root / "calls"
        return [json.loads(s) for s in path.read_text().splitlines()] if path.exists() else []

    def test_existing_launch_to_preparation_preserves_slots_and_providers(self):
        self.launch()
        before = len(self.calls())
        saved = self.receipt.read_bytes()
        code, result = self.handoff()
        self.assertEqual((code,result["status"]),(0,"prepared"),result)
        received = json.loads((self.root / "preparation-inputs").read_text())
        self.assertEqual(received["targets"],["1:BlueLake:codex:w9:p2","2:RedFox:claude:w9:p3"])
        self.assertEqual(received["sources"]["--scopes-file"],json.loads(self.scopes.read_text()))
        self.assertEqual([(name,argv[:2]) for name,argv in self.calls()[before:]],
            [("herdr",["agent","list"]),("herdr",["pane","process-info"]),("herdr",["pane","process-info"]),
             ("packet",["--prepare-batch",str(self.output)]),
             ("herdr",["agent","list"]),("herdr",["pane","process-info"]),("herdr",["pane","process-info"])])
        self.assertEqual(self.receipt.read_bytes(),saved)
        self.assertFalse(result["launch"]["starts_agents"])
        self.assertFalse(result["launch"]["work_dispatched"])
        # Explicit identities that aren't the ones launch registered.
        self.assertFalse(result["launch"]["agent_mail_registration_verified"])

    def test_preparation_defaults_to_the_agent_mail_names_launch_registered(self):
        self.launch()
        args = ["--prepare-batch",str(self.output),"--receipt",str(self.receipt),"--no-live-context",
                "--scopes-file",str(self.scopes)]
        code, result = self.invoke(args)
        self.assertEqual((code,result["status"]),(0,"prepared"),result)
        received = json.loads((self.root / "preparation-inputs").read_text())
        self.assertEqual(received["targets"],["1:GreenCastle:codex:w9:p2","2:AmberFox:claude:w9:p3"])
        self.assertTrue(result["launch"]["agent_mail_registration_verified"])

    def test_missing_intent_never_launches_or_prepares(self):
        code, _ = self.handoff()
        self.assertEqual(code,2)
        self.assertEqual(self.calls(),[])
        self.assertFalse(self.output.exists())

    def test_unconfirmed_intent_never_adopts_existing_panes(self):
        self.launch()
        result = self.root / "launch.json.result.json"
        result.rename(self.root / "retained-result.json")
        before = len(self.calls())
        code, report = self.handoff()
        self.assertEqual(code,2,report)
        self.assertEqual(len(self.calls()),before)
        self.assertFalse(self.output.exists())

    def test_changed_native_targets_block_before_preparation(self):
        self.launch()
        for mode in ("server-changed","pane-replaced","missing-pane","shell","wrong-repo"):
            with self.subTest(mode=mode):
                code, _ = self.handoff(mode=mode)
                self.assertEqual(code,2)
                self.assertFalse(self.output.exists())
        self.assertNotIn("packet",[name for name,_ in self.calls()])

    def test_identity_mapping_is_explicit_complete_and_unique(self):
        self.launch()
        before = len(self.calls())
        for identities in (("1:BlueLake",),("1:BlueLake","1:RedFox"),("1:BlueLake","2:bluelake"),
                           ("1:BlueLake","3:RedFox"),("1:$(touch x)","2:RedFox")):
            with self.subTest(identities=identities):
                self.assertEqual(self.handoff(identities=identities)[0],2)
        self.assertEqual(len(self.calls()),before)
        self.assertFalse(self.output.exists())

    def test_saved_assignments_keep_idle_slot_holes(self):
        self.launch()
        code, result = self.handoff(saved=True)
        self.assertEqual(code,0,result)
        received = json.loads((self.root / "preparation-inputs").read_text())
        self.assertEqual(received["targets"],["2:RedFox:claude:w9:p3"])

    def test_unknown_saved_assignment_slots_block_preparation(self):
        self.launch()
        for slots in ([3],[2,2],[True],[]):
            self.assignments.write_text(json.dumps({"assignments":[{"slot":s} for s in slots]}))
            self.assertEqual(self.handoff(saved=True)[0],2)
            self.assertFalse(self.output.exists())

    def test_saved_assignment_selection_overrides_are_rejected(self):
        self.launch()
        before = len(self.calls())
        self.assertEqual(self.handoff(saved=True,extra=("--roles","testing:2"))[0],2)
        self.assertEqual(len(self.calls()),before)

    def test_no_work_does_not_publish_or_offer_dispatch(self):
        self.launch()
        code, report = self.handoff(mode="no-work")
        self.assertEqual((code,report["status"]),(1,"no_work"))
        self.assertFalse(self.output.exists())
        self.assertNotIn("preview_command",report)

    def test_preparation_failure_preserves_launch_receipts(self):
        self.launch()
        saved = self.receipt.read_bytes()
        code, result = self.handoff(mode="preparation-failed")
        self.assertEqual(code,2,result)
        self.assertNotIn("private failure",json.dumps(result))
        self.assertEqual(self.receipt.read_bytes(),saved)

    def test_agent_changes_during_preparation_retains_bundle_without_success(self):
        self.launch()
        code, report = self.handoff(mode="change-during")
        self.assertEqual(code,2,report)
        self.assertTrue((self.output / "batch.json").exists())
        self.assertNotIn("preview_command",report)

    def test_private_result_required_and_never_overwritten(self):
        self.launch()
        path = self.root / "launch.json.result.json"
        data = path.read_bytes()
        path.chmod(0o644)
        code, _ = self.handoff()
        self.assertEqual(code,2)
        self.assertEqual(path.read_bytes(),data)
        self.assertFalse(self.output.exists())

    def test_duplicate_saved_panes_and_misordered_slots_are_rejected(self):
        self.launch()
        path = self.root / "launch.json.result.json"
        original = json.loads(path.read_text())
        for key,value in (("pane_id",original["targets"][0]["pane_id"]),("slot",1)):
            broken = json.loads(json.dumps(original))
            broken["targets"][1][key] = value
            path.write_text(json.dumps(broken))
            self.assertEqual(self.handoff()[0],2)
        self.assertFalse(self.output.exists())

    def test_existing_output_and_symlink_inputs_are_preserved(self):
        self.output.mkdir()
        keep = self.output / "keep"
        keep.write_text("user work")
        self.assertEqual(self.handoff()[0],2)
        self.assertEqual(keep.read_text(),"user work")
        self.output = self.root / "new-output"
        self.scopes.rename(self.root / "original-scopes.json")
        self.scopes.symlink_to(self.root / "original-scopes.json")
        self.assertEqual(self.handoff()[0],2)
        self.assertEqual(self.calls(),[])

    def test_relative_input_paths_refer_to_invocation_directory(self):
        self.launch()
        code, result = self.handoff(extra=("--scopes-file","scopes.json"))
        self.assertEqual(code,0,result)

    def test_real_preparer_and_allocator_consume_verified_launch(self):
        self.launch()
        shutil.copyfile(PACKET,self.lib / PACKET.name)
        shutil.copyfile(ASSIGN,self.lib / ASSIGN.name)
        (self.repo / "AGENTS.md").write_text("Follow current project instructions.\n")
        (self.repo / "README.md").write_text("Test project.\n")
        beads = [dict(id="bd-api",title="Implement API",status="open",issue_type="feature",priority=1,
                      description="Implement the endpoint",acceptance_criteria="Return 200",labels=["api"]),
                 dict(id="bd-doc",title="Document API",status="open",issue_type="task",priority=2,
                      description="Document the endpoint",acceptance_criteria="Example works",labels=["docs"])]
        path = self.root / "beads.json"
        path.write_text(json.dumps(beads))
        triage = self.root / "triage.json"
        triage.write_text("{}")
        code, result = self.handoff(extra=("--roles","implementation,documentation","--ready-file",str(path),
            "--beads-file",str(path),"--triage-file",str(triage)))
        self.assertEqual((code,result["status"]),(0,"prepared"),result)
        batch = json.loads((self.output / "batch.json").read_text())
        self.assertEqual([d["pane_id"] for d in batch["deliveries"]],["w9:p2","w9:p3"])
        self.assertEqual({d["workspace"] for d in batch["deliveries"]},{"w9"})
        self.assertEqual([d["agent_type"] for d in batch["deliveries"]],["codex","claude"])
        first = json.loads((self.output / "packet-01.json").read_text())
        self.assertEqual(first["agent"]["name"],"BlueLake")
        self.assertIn("Return 200",first["packet_markdown"])
        self.assertFalse(list(self.output.glob("*.receipt.json")))


class DispatchTests(unittest.TestCase):
    def setUp(self):
        self.case = HandoffTests("test_missing_intent_never_launches_or_prepares")
        self.case.setUp()
        self.addCleanup(self.case.doCleanups)
        self.case.launch()
        self.root, self.repo = self.case.root, self.case.repo
        (self.case.bin / "packet").write_text(DISPATCH_PACKET)
        self.bundle = self.root / "dispatch"
        self.bundle.mkdir(mode=0o700)
        self.batch = self.bundle / "batch.json"
        self.items = []
        for slot, kind, pane in ((1,"codex","w9:p2"),(2,"claude","w9:p3")):
            packet = {"schema_version":1,"status":"pass","repository":{"path":str(self.repo)},
                "agent":{"name":"BlueLake" if slot==1 else "RedFox"},"bead":{"id":f"bd-{slot}","status":"open"},
                "output":{"truncated":False},"packet_markdown":f"# ACFS Swarm Startup Packet\nDo task bd-{slot}.\n"}
            (self.bundle / f"packet-{slot}.json").write_text(json.dumps(packet))
            self.items.append({"repo":str(self.repo),"workspace":"w9","pane_id":pane,"agent_type":kind,
                "packet":f"packet-{slot}.json","operation_id":f"work-{slot}","receipt":f"delivery-{slot}.json"})
        self.write_batch()
        self.args = ["--dispatch-batch",str(self.batch),"--receipt",str(self.case.receipt)]

    def write_batch(self):
        self.batch.write_text(json.dumps({"schema":"acfs.packet-delivery-batch.v2","deliveries":self.items}))

    def invoke(self, mode="ok", review=None, send=False):
        args = list(self.args)
        if review is not None: args += ["--expect-sha256",review]
        if send: args += ["--send"]
        return self.case.invoke(args,mode)

    def preview(self):
        code, report = self.invoke()
        self.assertEqual((code,report["status"]),(0,"preview"),report)
        return report

    def sends(self):
        path = self.root / "sends"
        return [json.loads(s) for s in path.read_text().splitlines()] if path.exists() else []

    def assert_no_new_spawn(self):
        self.assertEqual(sum(name == "herdr" and argv[:2] == ["workspace","create"]
                             for name,argv in self.case.calls()),1)
        self.assertEqual(sum(name == "herdr" and argv[:2] == ["agent","start"] for name,argv in self.case.calls()),2)

    def test_preview_binds_original_launch_and_has_no_delivery_mutations(self):
        before = len(self.case.calls())
        report = self.preview()
        self.assertEqual(report["schema"],"acfs.swarm-dispatch.v1")
        self.assertFalse(report["sends_prompt"])
        self.assertFalse(report["starts_agents"])
        self.assertEqual([d["slot"] for d in report["deliveries"]],[1,2])
        self.assertEqual([d["action"] for d in report["deliveries"]],["submit","submit"])
        self.assertEqual(shlex.split(report["send_command"])[:4],["acfs","swarm","launch","--dispatch-batch"])
        self.assertNotIn("unguarded command",json.dumps(report))
        self.assertEqual([(n,a[:2]) for n,a in self.case.calls()[before:]],
            [("packet",["--deliver-batch",str(self.batch)]),
             ("herdr",["agent","list"]),("herdr",["pane","process-info"]),
             ("herdr",["agent","list"]),("herdr",["pane","process-info"])])
        self.assertFalse(list(self.bundle.glob("delivery-*")))
        self.assertEqual(self.sends(),[])
        self.assert_no_new_spawn()

    def test_dispatches_each_original_agent_once_and_reconciles(self):
        review = self.preview()["review_sha256"]
        for attempt in (0,1):
            before = len(self.case.calls())
            code, report = self.invoke(review=review,send=True)
            self.assertEqual((code,report["status"]),(0,"submitted"),report)
            self.assertEqual(report["summary"]["submitted"],2)
            self.assertEqual(report["summary"]["reconciled"],attempt*2)
            self.assertFalse(report["agent_execution_verified"])
            if attempt:
                # Reconciling reads the recorded results; it calls nothing that can send.
                self.assertEqual([n for n,_ in self.case.calls()[before:]],["packet"])
        self.assertEqual(len(self.sends()),2)
        for i in (1,2):
            expected = json.loads((self.bundle/f"packet-{i}.json").read_text())["packet_markdown"].encode()
            self.assertEqual((self.root/f"payload-work-{i}").read_bytes(),expected)
        self.assert_no_new_spawn()

    def test_packet_hash_or_unapproved_send_cannot_authorize_wrapper(self):
        report = self.preview()
        for review in (None,report["batch_review_sha256"],"0"*64):
            with self.subTest(review=review):
                self.assertEqual(self.invoke(send=True,review=review)[0],2)
        self.assertEqual(self.sends(),[])
        self.assertFalse(list(self.bundle.glob("delivery-*")))

    def test_other_workspace_repository_pane_or_provider_rejected(self):
        original = dict(self.items[1])
        for key,value in (("workspace","w8"),("repo",str(self.root)),("pane_id","w9:p99"),("agent_type","codex")):
            with self.subTest(key=key):
                self.items[1] = {**original,key:value}; self.write_batch()
                self.assertEqual(self.invoke()[0],2)
                self.assertEqual(self.sends(),[])

    def test_later_packet_change_invalidates_whole_review_before_first_send(self):
        review = self.preview()["review_sha256"]
        path = self.bundle/"packet-2.json"
        value = json.loads(path.read_text()); value["packet_markdown"] += "different work"
        path.write_text(json.dumps(value))
        code, report = self.invoke(send=True,review=review)
        self.assertEqual(code,2,report)
        self.assertEqual(self.sends(),[])

    def test_replaced_native_identity_stops_pending_work(self):
        review = self.preview()["review_sha256"]
        code, report = self.invoke(mode="pane-replaced",review=review,send=True)
        self.assertEqual((code,report["status"]),(2,"stopped"),report)
        self.assertEqual(report["summary"]["error"],1)
        self.assertEqual(report["summary"]["not_attempted"],1)
        self.assertEqual(self.sends(),[])
        self.assertFalse(report["submission_may_have_occurred"])

    def test_second_agent_replacement_after_first_send_stops_without_rollback(self):
        review = self.preview()["review_sha256"]
        code, report = self.invoke(mode="change-after-first",review=review,send=True)
        self.assertEqual((code,report["status"]),(2,"stopped"),report)
        self.assertEqual([d["status"] for d in report["deliveries"]],["submitted","error"])
        self.assertEqual(len(self.sends()),1)
        self.assertTrue((self.bundle/"delivery-1.json").exists())
        self.assertFalse((self.bundle/"delivery-2.json").exists())

    def test_lost_answer_stays_unconfirmed_and_never_resends(self):
        # herdr keeps no receipt to query, so a lost answer is never settled by
        # guessing: the intent stays unconfirmed and blocks later work.
        review = self.preview()["review_sha256"]
        code, report = self.invoke(mode="lost-first",review=review,send=True)
        self.assertEqual((code,report["status"]),(1,"stopped"),report)
        self.assertEqual([d["status"] for d in report["deliveries"]],["unconfirmed","not_attempted"])
        self.assertTrue(report["submission_may_have_occurred"])
        for _ in (0,1):
            code, report = self.invoke(review=review,send=True)
            self.assertEqual((code,report["status"]),(1,"stopped"),report)
            self.assertEqual([d["status"] for d in report["deliveries"]],["unconfirmed","not_attempted"])
            self.assertTrue(report["deliveries"][0]["reconciled_only"])
        self.assertEqual(len(self.sends()),1)
        self.assertFalse((self.bundle/"delivery-2.json").exists())

    def test_refused_delivery_is_recorded_and_stops_later_work(self):
        review = self.preview()["review_sha256"]
        code, report = self.invoke(mode="refused-first",review=review,send=True)
        self.assertEqual((code,report["status"]),(1,"stopped"),report)
        self.assertEqual([d["status"] for d in report["deliveries"]],["refused","not_attempted"])
        self.assertEqual(report["summary"]["refused"],1)
        self.assertFalse(report["submission_may_have_occurred"])
        code, report = self.invoke(review=review,send=True)
        self.assertEqual((code,report["status"]),(1,"stopped"),report)
        self.assertEqual(report["deliveries"][0]["status"],"refused")
        self.assertTrue(report["deliveries"][0]["reconciled_only"])
        self.assertEqual(self.sends(),[])
        self.assertFalse((self.bundle/"delivery-2.json").exists())

    def test_confirmed_submissions_reconcile_after_agents_exit(self):
        review = self.preview()["review_sha256"]
        self.assertEqual(self.invoke(review=review,send=True)[0],0)
        before = len(self.case.calls())
        code, report = self.invoke(mode="missing-pane",review=review,send=True)
        self.assertEqual((code,report["status"]),(0,"submitted"),report)
        self.assertEqual([n for n,_ in self.case.calls()[before:]],["packet"])
        self.assertEqual(report["summary"]["reconciled"],2)
        self.assertEqual(len(self.sends()),2)

    def test_recorded_result_must_match_request_target_and_shape(self):
        review = self.preview()["review_sha256"]
        self.assertEqual(self.invoke(review=review,send=True)[0],0)
        path = self.bundle/"delivery-1.json.result.json"
        original = path.read_text()
        good = json.loads(original)
        for name,value in (("digest",{**good,"request":{**good["request"],"payload_sha256":"0"*64}}),
                           ("target",{**good,"target":"term_99"}),("status",{**good,"status":"delivered"}),
                           ("scalar",[])):
            with self.subTest(name=name):
                path.write_text(json.dumps(value))
                code, report = self.invoke(review=review,send=True)
                self.assertEqual((code,report["status"]),(1,"stopped"),report)
                self.assertEqual(report["deliveries"][0]["status"],"unconfirmed")
        path.write_text(original)
        path.chmod(0o644)
        code, report = self.invoke(review=review,send=True)
        self.assertEqual((code,report["deliveries"][0]["status"]),(1,"unconfirmed"),report)
        self.assertEqual(len(self.sends()),2)

    def test_removing_known_intent_during_validation_cannot_turn_query_into_send(self):
        review = self.preview()["review_sha256"]
        self.assertEqual(self.invoke(review=review,send=True)[0],0)
        code, report = self.invoke(mode="remove-intent-after-preview",review=review,send=True)
        self.assertEqual((code,report["status"]),(0,"submitted"),report)
        self.assertEqual(report["summary"]["reconciled"],2)
        self.assertEqual(len(self.sends()),2)
        self.assertTrue((self.bundle/"delivery-1.json.retained").exists())

    def test_packet_changed_during_dispatch_fails_at_child_hash_check(self):
        review = self.preview()["review_sha256"]
        code, report = self.invoke(mode="mutate-after-preview",review=review,send=True)
        self.assertEqual((code,report["status"]),(2,"stopped"),report)
        self.assertEqual([d["status"] for d in report["deliveries"]],["submitted","error"])
        self.assertEqual(len(self.sends()),1)

    def test_malformed_child_response_marks_possible_submission_and_stops(self):
        review = self.preview()["review_sha256"]
        code, report = self.invoke(mode="bad-child-response",review=review,send=True)
        self.assertEqual((code,report["status"]),(2,"stopped"),report)
        self.assertTrue(report["submission_may_have_occurred"])
        self.assertTrue((self.bundle/"delivery-1.json").exists())
        code, report = self.invoke(review=review,send=True)
        self.assertEqual(code,0,report)
        self.assertEqual(report["summary"]["reconciled"],1)
        self.assertEqual(len(self.sends()),2)

    def test_incomplete_launch_never_dispatches_or_respawns(self):
        path = self.root/"launch.json.result.json"
        path.rename(self.root/"kept-result.json")
        before = len(self.case.calls())
        self.assertEqual(self.invoke()[0],2)
        self.assertEqual(len(self.case.calls()),before)
        self.assertEqual(self.sends(),[])
        self.assert_no_new_spawn()

    def test_active_launch_directory_lock_excludes_dispatch(self):
        import fcntl
        review = self.preview()["review_sha256"]
        fd = os.open(self.root,os.O_RDONLY|os.O_DIRECTORY)
        try:
            fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
            before = len(self.case.calls())
            self.assertEqual(self.invoke(review=review,send=True)[0],2)
            self.assertEqual(len(self.case.calls()),before)
        finally:
            os.close(fd)
        self.assertEqual(self.sends(),[])

    def test_real_launch_prepare_review_dispatch_and_reconcile(self):
        herdr = HerdrStub([agent_row("w9:p2",self.repo,agent="codex",terminal_id="term_2"),
                           agent_row("w9:p3",self.repo,terminal_id="term_3")])
        self.addCleanup(herdr.close)
        self.case.env = herdr.env(self.case.env)
        shutil.copyfile(PACKET,self.case.lib/PACKET.name)
        shutil.copyfile(ASSIGN,self.case.lib/ASSIGN.name)
        path = self.case.bin/"br"; path.write_text(PROBE); path.chmod(0o755)
        (self.repo/"AGENTS.md").write_text("Follow current code.\n")
        (self.repo/"README.md").write_text("Demo project.\n")
        beads = [dict(id="bd-api",title="Implement API",status="open",issue_type="feature",priority=1,
                    description="Implement endpoint",acceptance_criteria="Return 200",labels=["api"]),
                 dict(id="bd-doc",title="Document API",status="open",issue_type="task",priority=2,
                    description="Document endpoint",acceptance_criteria="Working example",labels=["docs"])]
        path = self.root/"beads.json"; path.write_text(json.dumps(beads))
        triage = self.root/"triage.json"; triage.write_text("{}")
        code, prepared = self.case.handoff(extra=("--roles","implementation,documentation",
            "--ready-file",str(path),"--beads-file",str(path),"--triage-file",str(triage)))
        self.assertEqual(code,0,prepared)
        command = shlex.split(prepared["preview_command"])
        self.assertEqual(command[:4],["acfs","swarm","launch","--dispatch-batch"])
        code, preview = self.case.invoke(command[3:])
        self.assertEqual(code,0,preview)
        send = shlex.split(preview["send_command"])[3:]
        code, result = self.case.invoke(send)
        self.assertEqual((code,result["status"]),(0,"submitted"),result)
        code, result = self.case.invoke(send,mode="missing-pane")
        self.assertEqual(code,0,result)
        self.assertEqual(result["summary"]["reconciled"],2)
        self.assertEqual([p["target"] for p in herdr.prompts()],["w9:p2","w9:p3"])
        self.assertTrue(all(p["text"].startswith("# ACFS Swarm Startup Packet\n") for p in herdr.prompts()))
        self.assert_no_new_spawn()


if __name__ == "__main__":
    unittest.main()
