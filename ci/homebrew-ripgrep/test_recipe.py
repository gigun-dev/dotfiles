import os,pathlib,subprocess,tempfile,unittest
ROOT=pathlib.Path(__file__).resolve().parent
class Preflight(unittest.TestCase):
 def run_recipe(self,args,platform='Darwin x86_64'):
  with tempfile.TemporaryDirectory() as td:
   p=pathlib.Path(td);log=p/'calls'
   for name,body in {'uname':f'echo "{platform}"','sw_vers':'echo 15.7.9','brew':f'echo "$*" >> "{log}"; if [ "$1" = --prefix ]; then echo /usr/local; fi'}.items():
    q=p/name;q.write_text('#!/bin/sh\n'+body+'\n');q.chmod(0o755)
   env=os.environ.copy();env['PATH']=td+':'+env['PATH']
   r=subprocess.run(['bash',str(ROOT/'recipe.sh'),*args],env=env,capture_output=True,text=True)
   return r,log.read_text() if log.exists() else ''
 def test_default_is_read_only(self):
  r,c=self.run_recipe([]);self.assertEqual(r.returncode,0,r.stderr);self.assertEqual(c.splitlines(),['--prefix','list --versions pcre2 ripgrep'])
 def test_mutation_requires_explicit_execute(self):
  r,c=self.run_recipe(['build','/tmp/not-used']);self.assertNotEqual(r.returncode,0);self.assertEqual(c.splitlines(),['--prefix'])
 def test_other_architecture_is_rejected(self):
  r,c=self.run_recipe([],platform='Darwin arm64');self.assertNotEqual(r.returncode,0);self.assertEqual(c,'')
if __name__=='__main__':unittest.main()
