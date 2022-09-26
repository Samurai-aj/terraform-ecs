terraform {
  required_providers {

    docker = {
      source  = "kreuzwerker/docker"
      version = "2.22.0"
    }

    aws = {
      source  = "hashicorp/aws"
      version = "4.30.0"
    }

  }
}

provider "aws" {
  region = "us-west-1"
}

provider "docker" {

}
