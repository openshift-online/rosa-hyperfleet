resource "aws_cloudfront_origin_access_control" "oidc" {
  name                              = "${var.regional_id}-oidc"
  description                       = "OAC for regional HyperShift OIDC S3 bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "oidc" {
  enabled     = true
  comment     = "Regional OIDC endpoint for ${var.regional_id}"
  price_class = "PriceClass_100"

  origin {
    domain_name              = aws_s3_bucket.oidc.bucket_regional_domain_name
    origin_id                = "oidc-s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.oidc.id
  }

  default_cache_behavior {
    target_origin_id       = "oidc-s3"
    viewer_protocol_policy = "https-only"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = {
    Name = "${var.regional_id}-oidc"
  }
}