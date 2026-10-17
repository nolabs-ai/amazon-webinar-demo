terraform {
  backend "s3" {
    bucket       = "webinar-kata-kernel-816301968846"
    key          = "tfstate/webinar-kata.tfstate"
    region       = "eu-west-1"
    encrypt      = true
    use_lockfile = true
  }
}
