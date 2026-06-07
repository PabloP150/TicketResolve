# Delivery 3 — state migration for the API Gateway.
#
# In Delivery 2 the HTTP API and its routes/integrations/stage/permissions
# lived inline in the root module. Delivery 3 extracts them into
# modules/ingress/ for separation of concerns. These moved{} blocks rename the
# existing state addresses so Terraform migrates them in place instead of
# destroying and recreating the live D2 ingress.

moved {
  from = aws_apigatewayv2_api.main
  to   = module.ingress.aws_apigatewayv2_api.this
}

moved {
  from = aws_apigatewayv2_integration.api_tickets
  to   = module.ingress.aws_apigatewayv2_integration.api_tickets
}

moved {
  from = aws_apigatewayv2_integration.webhook_ingesta
  to   = module.ingress.aws_apigatewayv2_integration.webhook
}

moved {
  from = aws_apigatewayv2_route.incidents
  to   = module.ingress.aws_apigatewayv2_route.incidents_post
}

moved {
  from = aws_apigatewayv2_route.webhooks
  to   = module.ingress.aws_apigatewayv2_route.webhooks_post
}

moved {
  from = aws_apigatewayv2_stage.default
  to   = module.ingress.aws_apigatewayv2_stage.default
}

moved {
  from = aws_lambda_permission.apigw_api_tickets
  to   = module.ingress.aws_lambda_permission.api_tickets
}

moved {
  from = aws_lambda_permission.apigw_webhook_ingesta
  to   = module.ingress.aws_lambda_permission.webhook
}
