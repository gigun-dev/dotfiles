{ lib, ... }:
{
  # Unimported draft. The matching Lima export removal requires a planned restart.
  fileSystems."/Users/gigun".enable = lib.mkForce false;
}
