//provisioner
provider "aws" {
  version = "~> 2.0"
  region  = "ap-south-1"
  profile = "bmbterra"
}

//security group
resource "aws_security_group" "allow_http_ssh"{
  name = "allow_http_ssh"
  description = "webserver that allows http"
vpc_id = "vpc-fe697596"

ingress{
  description ="allows http"
  from_port = 80
  to_port = 80
  protocol = "tcp"
  cidr_blocks = ["0.0.0.0/0"]
}

ingress{
  description  = "allows NFS"
  from_port = 2049
  to_port = 2049
  protocol = "tcp"
  cidr_blocks = ["0.0.0.0/0"]
}

ingress{
  description  = "allows ssh"
  from_port = 22
  to_port = 22
  protocol = "tcp"
  cidr_blocks = ["0.0.0.0/0"]
}

egress{
  description = "allows all ports"
  from_port = 0
  to_port = 0
  protocol = "-1"
  cidr_blocks = ["0.0.0.0/0"]
}

  tags = {
    Name = "HTTP_SSH"
  }
} //closes resource


//launches ec2 t2.micro instance
resource "aws_instance" "webserver"{
  depends_on = [aws_security_group.allow_http_ssh]
  instance_type = "t2.micro"
  ami = "ami-0732b62d310b80e97"
  security_groups = [aws_security_group.allow_http_ssh.name]
  key_name = "terra2"

  tags = {
    Name = "webserver"
  }

}//closes ec2 resource


//creates efs storage
resource "aws_efs_file_system" "efs_storage"{
  depends_on = [aws_instance.webserver]
  creation_token = "web_efs"
  tags = {
    Name = "web_efs"
  }
}//closses efs storage


//creates a mount target for efs_storage
resource "aws_efs_mount_target" "alpha" {
  depends_on = [aws_efs_file_system.efs_storage]
  file_system_id = "${aws_efs_file_system.efs_storage.id}"
  subnet_id      = "${aws_instance.webserver.subnet_id}"
  security_groups = ["${aws_security_group.allow_http_ssh.id}"]
}


resource "null_resource" "mounts_efs" {
  depends_on = [aws_efs_mount_target.alpha]
  //connects  to ec2 instance
  connection{
    type = "ssh"
    user = "ec2-user"
    host = aws_instance.webserver.public_ip
    private_key = file("C:/Users/Mishan Regmi/Downloads/terra2.pem")
  }

    //installs nfs util
    provisioner "remote-exec"{
      inline = [
        "sudo yum install git -y",
        "sudo yum install httpd -y",
        "sudo yum install php -y",
        "sudo systemctl start httpd",
        "sudo systemctl enable httpd",
        "sudo mount -t nfs -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport ${aws_efs_file_system.efs_storage.dns_name}:/ /var/www/html",
        "sudo df -h",
        "sudo rm -rf /var/www/html/*",
        "sudo git clone --single-branch --branch master https://github.com/yobahBertrandYonkou/hmctask1.git  /var/www/html"
      ]
    }
}


//creates an s3 bucket
resource "aws_s3_bucket" "cf_bucket" {
  depends_on = [null_resource.mounts_efs]
  bucket = "bmbvfx"
  acl    = "public-read"

  tags = {
    Name = "cloudF_bucket"
  }
}

//uploads all images to s3 bucket
resource "aws_s3_bucket_object" "upload_images" {
depends_on = [ aws_s3_bucket.cf_bucket ]
  for_each = fileset("C:/images/", "**/**.jpg")
  force_destroy = true
  content_type = "image/jpg"
  bucket = aws_s3_bucket.cf_bucket.bucket
  key    = each.value
  source = "C:/images/${each.value}"
}

locals {
  s3_origin_id = "S3-bmbvfx"
}

//creates an origin acess indetity for cf
resource "aws_cloudfront_origin_access_identity" "origin_access_identity" {
  comment = "let_me_pass"
}


//creates a cloudFront distribution
resource "aws_cloudfront_distribution" "cloud_front_dist" {
depends_on = [ aws_s3_bucket.cf_bucket ]
  origin {
    domain_name = "${aws_s3_bucket.cf_bucket.bucket_regional_domain_name}"
    origin_id   = "${local.s3_origin_id}"


      s3_origin_config {
      origin_access_identity = "${aws_cloudfront_origin_access_identity.origin_access_identity.cloudfront_access_identity_path}"
    }
  }

  enabled             = true
  is_ipv6_enabled     = true


  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "${local.s3_origin_id}"

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "allow-all"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }


  restrictions {
    geo_restriction {
      restriction_type = "blacklist"
      locations        = ["DE"]
    }
  }

  tags = {
    env = "testing"
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

//updating bucket policy
data "aws_iam_policy_document" "s3_policy" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.cf_bucket.arn}/*"]

    principals {
      type        = "AWS"
      identifiers = ["${aws_cloudfront_origin_access_identity.origin_access_identity.iam_arn}"]
    }
  }

  statement {
    actions   = ["s3:ListBucket"]
    resources = ["${aws_s3_bucket.cf_bucket.arn}"]

    principals {
      type        = "AWS"
      identifiers = ["${aws_cloudfront_origin_access_identity.origin_access_identity.iam_arn}"]
    }
  }
}

resource "aws_s3_bucket_policy" "bmbvfx_policy" {
  depends_on = [ aws_s3_bucket.cf_bucket, aws_cloudfront_distribution.cloud_front_dist ]
  bucket = "${aws_s3_bucket.cf_bucket.id}"
  policy = "${data.aws_iam_policy_document.s3_policy.json}"
}



variable "default_url" {
default = "cloudFrontUrl"
}

//updating code in /var/www/html with CF Url
resource "null_resource" "set_cf_url" {
depends_on = [ aws_cloudfront_distribution.cloud_front_dist ]
connection {
type = "ssh"
user = "ec2-user"
host = aws_instance.webserver.public_ip
private_key = file("C:/Users/Mishan Regmi/Downloads/terra2.pem")
}

provisioner "remote-exec" {
inline =[ "sudo sed -i 's/${var.default_url}/${aws_cloudfront_distribution.cloud_front_dist.domain_name}/g' /var/www/html/index.html" ] 
}
}

resource "null_resource" "connect_to_site"{
  depends_on = [aws_cloudfront_distribution.cloud_front_dist, null_resource.set_cf_url, aws_s3_bucket_policy.bmbvfx_policy]
  provisioner "local-exec"{
    command = "chrome ${aws_instance.webserver.public_dns}"
  }
}
