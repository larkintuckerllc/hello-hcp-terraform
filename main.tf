provider "google" {
  project = "skillful-figure-459619-t4"
}

resource "google_storage_bucket" "that" {
  name     = "my-terraform-bucket-0"
  location = "US"

  force_destroy = false

  labels = {
    managed-by  = "terraform"
    environment = "learning"
  }
}
