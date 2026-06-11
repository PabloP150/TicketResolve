# Demo file to trigger a failing `terraform fmt` required check for the
# ruleset-blocked-merge.png evidence screenshot. Delete after capturing.
locals {
  fmt_demo_bad_spacing =    "this line is intentionally mis-formatted"
}
