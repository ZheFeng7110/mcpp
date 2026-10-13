"""Exercise the real compile-admit wrapper with bounded subprocess waits."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest


MCPP = os.environ.get("MCPP", "")


@unittest.skipUnless(MCPP, "set MCPP to the freshly built executable")
class CompileAdmit(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="mcpp-admit-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.sem = self.root / "tokens"

    def argv(self, script, *args, baseline=0, bmi=None):
        cmd = [MCPP, "compile-admit", "--sem", str(self.sem),
               "--mem-baseline", str(baseline), "--mem-threshold", "1"]
        if bmi is not None:
            cmd += ["--bmi-restat", str(bmi)]
        return cmd + ["--", sys.executable, "-c", script, *map(str, args)]

    def run_compile(self, script, *args, **kwargs):
        return subprocess.run(self.argv(script, *args, **kwargs),
                              capture_output=True, text=True, timeout=10)

    @unittest.skipIf(os.name == "nt", "POSIX BMI restat contract")
    def test_bmi_restore_and_failure_cleanup(self):
        bmi = self.root / "interface.pcm"
        old_time = 1_600_000_000_000_000_000
        writer = "import pathlib,sys; pathlib.Path(sys.argv[1]).write_bytes(sys.argv[2].encode())"
        for content, status, expected in (("same", 0, b"same"),
                                           ("changed", 0, b"changed"),
                                           ("failed", 7, b"failed")):
            with self.subTest(content=content):
                bmi.write_bytes(b"same")
                os.utime(bmi, ns=(old_time, old_time))
                result = self.run_compile(writer + f"; sys.exit({status})",
                                          bmi, content, bmi=bmi)
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertEqual(bmi.read_bytes(), expected)
                if content == "same":
                    self.assertEqual(bmi.stat().st_mtime_ns, old_time)
                else:
                    self.assertNotEqual(bmi.stat().st_mtime_ns, old_time)
                self.assertFalse(Path(str(bmi) + ".bak").exists())
        bmi.unlink()
        result = self.run_compile(writer, bmi, "new", bmi=bmi)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(bmi.read_bytes(), b"new")

    @unittest.skipIf(os.name == "nt", "POSIX BMI restat contract")
    def test_equivalent_bmi_does_not_cascade_in_ninja(self):
        ninja = shutil.which("ninja")
        if not ninja:
            self.skipTest("ninja unavailable")
        source = self.root / "source"
        source.write_text("same")
        helper = self.root / "compile.py"
        helper.write_text("from pathlib import Path\nPath('interface.pcm').write_bytes(b'same')\n")
        consumer = self.root / "consumer.py"
        consumer.write_text("from pathlib import Path\nPath('consumer').touch()\n")
        (self.root / "build.ninja").write_text(
            f'rule bmi\n  command = "{MCPP}" compile-admit --sem tokens '
            f'--mem-baseline 0 --bmi-restat "$out" -- "{sys.executable}" "{helper}"\n'
            '  restat = 1\n'
            f'rule consume\n  command = "{sys.executable}" "{consumer}"\n'
            'build interface.pcm: bmi source\n'
            'build consumer: consume interface.pcm\n')
        def build():
            result = subprocess.run([ninja, "-f", "build.ninja"], cwd=self.root,
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
        build()
        before = (self.root / "consumer").stat().st_mtime_ns
        time.sleep(.05)
        source.touch()
        build()
        self.assertEqual((self.root / "consumer").stat().st_mtime_ns, before)


if __name__ == "__main__":
    unittest.main()
