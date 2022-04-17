require "./spec_helper"

require "../src/crd"

crds_yaml = <<-YAML
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: rails-apps.jgaskins.dev
spec:
  group: jgaskins.dev
  versions:
  - name: v1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            properties:
              image: { type: string }
              env:
                type: array
                items:
                  type: object
                  properties: { name: { type: string }, value: { type: string } }
              envFrom:
                type: array
                default: []
                items:
                  type: object
                  properties:
                    secretRef:
                      type: object
                      nullable: true
                      properties:
                        name:
                          type: string
                      required:
                        - name
              web:
                type: object
                properties:
                  command:
                    type: array
                    items: { type: string }
              worker:
                type: object
                properties:
                  command:
                    type: array
                    items:
                      type: string
  scope: Namespaced
  names:
    plural: rails-apps
    singular: rails-app
    kind: RailsApp
    shortNames:
    - rails
    - ra
YAML
resource_yaml = <<-YAML
apiVersion: jgaskins.dev/v1
kind: RailsApp
metadata:
  name: forem
  namespace: example-forem
spec:
  image: quay.io/forem/forem:latest
  env:
    - name: RAILS_ENV
      value: production
  web:
    command: ["bundle", "exec", "rails", "server"]
  worker:
    command: ["bundle", "exec", "sidekiq"]
YAML

describe Kubernetes::CRD do
  crd = Kubernetes::CRD.from_yaml yaml

  it "idk lol" do
    spec = crd.spec
    v1 = spec.versions.first
    properties = v1.schema.open_api_v3_schema.properties.spec.properties

    properties["image"].type.should eq "string"
    properties.to_crystal.should contain "image : String"

    properties["env"].type.should eq "array"
    if items = properties["env"].items
      items.type.should eq "object"
      items.properties["name"].type.should eq "string"
      items.properties["value"].type.should eq "string"
    else
      raise "env.items should not be nil!"
    end
    properties.to_crystal.should contain "env : Array(Env)"

    properties["web"].type.should eq "object"
    properties["web"].properties["command"].type.should eq "array"
    properties["web"].properties["command"].items.not_nil!.type.should eq "string"
    properties["envFrom"].default.not_nil!.as_a.empty?.should eq true
  end
end
