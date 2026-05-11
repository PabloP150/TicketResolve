# TicketResolve — Cloud Infrastructure

[![Terraform CI](https://github.com/PabloP150/TicketResolve/actions/workflows/terraform-ci.yml/badge.svg?branch=main)](https://github.com/PabloP150/TicketResolve/actions/workflows/terraform-ci.yml)

Repositorio compartido entre los cursos **Infraestructura en la Nube** y **Optimizaciones y Performance** (PDDS — Galileo).

Este repositorio contiene:

- La aplicación TicketResolve (a desarrollar en próximas entregas).
- La infraestructura como código (Terraform) que la aprovisiona, bajo [`infra/`](infra/).
- El pipeline de CI/CD (GitHub Actions) que valida cambios a la infraestructura, bajo [`.github/workflows/`](.github/workflows/).

## Deliveries del curso de Optimizaciones y Performance

| Delivery | Tag                | Resumen                                                  |
| -------- | ------------------ | -------------------------------------------------------- |
| 1        | `oyd-delivery-1`   | IaC Workspace Bootstrap & CI Pipeline                    |
| 2        | `oyd-delivery-2`   | Compute, Storage, Database + Remote State (pendiente)    |
| 3        | `oyd-delivery-3`   | Networking (pendiente)                                   |
| 4        | `oyd-delivery-4`   | Async Processing (pendiente)                             |
| 5        | `oyd-delivery-5`   | Security & Observability + OIDC (pendiente)              |

Para detalles de uso de Terraform y del pipeline, ver [`infra/README.md`](infra/README.md).
Para el resumen de cada entrega, ver [`infra/docs/`](infra/docs/).

## Track elegido

- **Standard track** (no EKS).
- **CI provider:** GitHub Actions.
