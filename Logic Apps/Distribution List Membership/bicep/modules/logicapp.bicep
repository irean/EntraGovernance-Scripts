metadata description = '''Logic app deployment,
contains everything related to the logic app part of the solution.
Should only be called as a module from main.bicep, not directly.'''

@description('Name of the Logic App (Consumption) resource to create.')
param logicAppName string

@description('Azure region for the Logic App.')
param location string

@description('User-Assigned Managed Identity set up by main.bicep')
param userAssignedIdentityResourceId string

@description('Id of the Entra ID Governance Access Package Catalog this Logic App should react to.')
param accessPackageCatalogId string

@description('''Maps an Access Package Id to the array of distribution list SMTP addresses that
should be added/removed for it. One package may map to multiple lists.''')
param distributionListMapping object = {
  '<access-package-id-1>': [
    'group-a@example.com'
    'group-b@example.com'
  ]
  '<access-package-id-2>': [
    'group-c@example.com'
  ]
}

@description('Full HTTPS URL of the DistributionListMembership function endpoint, e.g. https://<your-function-app>.azurewebsites.net/api/DistributionListMembership')
param functionUri string

@description('''App ID URI (audience) of the App Registration that fronts the Function App,
e.g. api://<app-id>. The user-assigned identity above must hold an app role assignment on this
application.''')
param functionAudience string

@description('''Free-text 'source' value sent in the best-effort status report back to
Microsoft Graph. Purely cosmetic - shows up in the Entra assignment's extension status.''')
param callbackSourceName string

@description('''The appid claim of the Microsoft Entra ID Governance service identity allowed to
invoke this trigger via an AADPOP (proof-of-possession) token''')
param governanceCallerAppId string

resource logicApp 'Microsoft.Logic/workflows@2019-05-01' = {
  name: logicAppName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentityResourceId}': {}
    }
  }
  properties: {
    state: 'Enabled'
    accessControl: {
      triggers: {
        openAuthenticationPolicies: {
          policies: {
            EntraIdGovernanceOnly: {
              type: 'AADPOP'
              claims: [
                {
                  name: 'iss'
                  value: 'https://sts.windows.net/${subscription().tenantId}/'
                }
                {
                  name: 'appid'
                  value: governanceCallerAppId
                }
                {
                  name: 'm'
                  value: 'POST'
                }
                {
                  name: 'u'
#disable-next-line no-hardcoded-env-urls
                  value: 'management.azure.com'
                }
                {
                  name: 'p'
                  value: resourceId('Microsoft.Logic/workflows', logicAppName)
                }
              ]
            }
          }
        }
      }
    }
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      parameters: {
        accessPackageCatalogId: {
          type: 'string'
        }
        distributionListMapping: {
          type: 'object'
        }
        functionUri: {
          type: 'string'
        }
        functionAudience: {
          type: 'string'
        }
        userAssignedIdentityResourceId: {
          type: 'string'
        }
        callbackSourceName: {
          type: 'string'
        }
      }
      triggers: {
        manual: {
          type: 'Request'
          kind: 'Http'
          inputs: {
            schema: {
              type: 'object'
              properties: {
                AccessPackageAssignmentRequestId: {
                  type: 'string'
                }
                CallbackUriPath: {
                  type: 'string'
                }
                CustomExtensionStageInstanceId: {
                  type: 'string'
                }
                Stage: {
                  type: 'string'
                }
                RequestType: {
                  type: 'string'
                }
                Answers: {
                  type: 'array'
                }
                State: {
                  type: 'string'
                }
                Status: {
                  type: 'string'
                }
                CallbackConfiguration: {
                  type: 'object'
                  properties: {
                    DurationBeforeTimeout: {
                      type: 'string'
                    }
                  }
                }
                AccessPackage: {
                  type: 'object'
                  properties: {
                    Id: {
                      type: 'string'
                    }
                    DisplayName: {
                      type: 'string'
                    }
                    Description: {
                      type: 'string'
                    }
                  }
                }
                AccessPackageCatalog: {
                  type: 'object'
                  properties: {
                    Id: {
                      type: 'string'
                    }
                    DisplayName: {
                      type: 'string'
                    }
                    Description: {
                      type: 'string'
                    }
                  }
                }
                Assignment: {
                  type: 'object'
                  properties: {
                    Id: {
                      type: 'string'
                    }
                    Target: {
                      type: 'object'
                      properties: {
                        ConnectedOrganization: {
                          type: 'object'
                          properties: {
                            Id: {
                              type: 'string'
                            }
                            DisplayName: {
                              type: 'string'
                            }
                            Description: {
                              type: 'string'
                            }
                          }
                        }
                        Id: {
                          type: 'string'
                        }
                        ObjectId: {
                          type: 'string'
                        }
                        DisplayName: {
                          type: 'string'
                        }
                      }
                    }
                    State: {
                      type: 'string'
                    }
                    Status: {
                      type: 'string'
                    }
                    AssignmentPolicy: {
                      type: 'object'
                      properties: {
                        Id: {
                          type: 'string'
                        }
                        DisplayName: {
                          type: 'string'
                        }
                      }
                    }
                  }
                }
                Requestor: {
                  type: 'object'
                  properties: {
                    Id: {
                      type: 'string'
                    }
                    ObjectId: {
                      type: 'string'
                    }
                    DisplayName: {
                      type: 'string'
                    }
                  }
                }
              }
            }
          }
          operationOptions: 'IncludeAuthorizationHeadersInOutputs'
        }
      }
      actions: {
        Initialize_Action: {
          type: 'InitializeVariable'
          inputs: {
            variables: [
              {
                name: 'Action'
                type: 'string'
                value: '@if(contains(createArray(\'adminAdd\', \'userAdd\', \'systemAdd\'), triggerBody()?[\'RequestType\']), \'Add\', if(contains(createArray(\'adminRemove\', \'userRemove\', \'systemRemove\', \'systemExpire\'), triggerBody()?[\'RequestType\']), \'Remove\', \'\'))'
              }
            ]
          }
          runAfter: {}
        }
        // The access package -> DL mapping lives HERE
        // Edit this value directly in the Logic App (Portal > Logic app code
        // view, or open this action in the Designer)
        Initialize_DistributionListMapping: {
          type: 'InitializeVariable'
          inputs: {
            variables: [
              {
                name: 'DistributionListMapping'
                type: 'object'
                value: distributionListMapping
              }
            ]
          }
          runAfter: {
            Initialize_Action: [
              'Succeeded'
            ]
          }
        }
        Condition_InScopeCatalog: {
          type: 'If'
          expression: {
            and: [
              {
                equals: [
                  '@triggerBody()?[\'AccessPackageCatalog\']?[\'Id\']'
                  '@parameters(\'accessPackageCatalogId\')'
                ]
              }
            ]
          }
          runAfter: {
            Initialize_DistributionListMapping: [
              'Succeeded'
            ]
          }
          actions: {
            Condition_HasValidAction: {
              type: 'If'
              expression: {
                and: [
                  {
                    not: {
                      equals: [
                        '@variables(\'Action\')'
                        ''
                      ]
                    }
                  }
                ]
              }
              runAfter: {}
              actions: {
                Get_TargetDLs: {
                  type: 'Compose'
                  runAfter: {}
                  inputs: '@variables(\'DistributionListMapping\')?[triggerBody()?[\'AccessPackage\']?[\'Id\']]'
                }
                Condition_HasMappedDLs: {
                  type: 'If'
                  expression: {
                    and: [
                      {
                        greater: [
                          '@length(coalesce(outputs(\'Get_TargetDLs\'), createArray()))'
                          0
                        ]
                      }
                    ]
                  }
                  runAfter: {
                    Get_TargetDLs: [
                      'Succeeded'
                    ]
                  }
                  actions: {
                    Call_Function_DistributionListMembership: {
                      type: 'Http'
                      runAfter: {}
                      inputs: {
                        method: 'POST'
                        uri: '@parameters(\'functionUri\')'
                        headers: {
                          'Content-type': 'application/json'
                        }
                        body: {
                          UserId: '@{triggerBody()?[\'Assignment\']?[\'Target\']?[\'ObjectId\']}'
                          Action: '@{variables(\'Action\')}'
                          DistributionLists: '''@outputs('Get_TargetDLs')'''
                          AccessPackageAssignmentRequestId: '@{triggerBody()?[\'AccessPackageAssignmentRequestId\']}'
                        }
                        authentication: {
                          type: 'ManagedServiceIdentity'
                          identity: '@parameters(\'userAssignedIdentityResourceId\')'
                          audience: '@parameters(\'functionAudience\')'
                        }
                      }
                      runtimeConfiguration: {
                        contentTransfer: {
                          transferMode: 'Chunked'
                        }
                      }
                    }
                    Parse_Function_Response: {
                      type: 'ParseJson'
                      runAfter: {
                        Call_Function_DistributionListMembership: [
                          'Succeeded'
                        ]
                      }
                      inputs: {
                        content: '@body(\'Call_Function_DistributionListMembership\')'
                        schema: {
                          type: 'object'
                          properties: {
                            OverallStatus: {
                              type: 'string'
                            }
                            Results: {
                              type: 'array'
                              items: {
                                type: 'object'
                                properties: {
                                  DistributionList: {
                                    type: 'string'
                                  }
                                  Status: {
                                    type: 'string'
                                  }
                                  Note: {
                                    type: 'string'
                                  }
                                  Error: {
                                    type: 'string'
                                  }
                                }
                              }
                            }
                          }
                        }
                      }
                    }
                    Condition_OverallStatus_NotSuccess: {
                      type: 'If'
                      expression: {
                        and: [
                          {
                            not: {
                              equals: [
                                '@body(\'Parse_Function_Response\')?[\'OverallStatus\']'
                                'Success'
                              ]
                            }
                          }
                        ]
                      }
                      runAfter: {
                        Parse_Function_Response: [
                          'Succeeded'
                        ]
                      }
                      actions: {
                        Compose_FailureSummary: {
                          type: 'Compose'
                          runAfter: {}
                          inputs: {
                            AccessPackageAssignmentRequestId: '@{triggerBody()?[\'AccessPackageAssignmentRequestId\']}'
                            UserId: '@{triggerBody()?[\'Assignment\']?[\'Target\']?[\'ObjectId\']}'
                            OverallStatus: '@{body(\'Parse_Function_Response\')?[\'OverallStatus\']}'
                            Results: '@{body(\'Parse_Function_Response\')?[\'Results\']}'
                          }
                        }
                      }
                      else: {
                        actions: {}
                      }
                    }
                    Report_Completion_To_Entra_BestEffort: {
                      type: 'Http'
                      runAfter: {
                        Condition_OverallStatus_NotSuccess: [
                          'Succeeded'
                          'Failed'
                          'Skipped'
                          'TimedOut'
                        ]
                      }
                      inputs: {
                        method: 'POST'
                        uri: 'https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/accessPackageAssignmentRequests/@{triggerBody()?[\'AccessPackageAssignmentRequestId\']}/resume'
                        headers: {
                          'Content-type': 'application/json'
                        }
                        body: {
                          source: '@{parameters(\'callbackSourceName\')}'
                          type: 'microsoft.graph.accessPackageCustomExtensionStage.@{triggerBody()?[\'Stage\']}'
                          data: {
                            // Logic Apps' Workflow Definition Language evaluates ANY string
                            // starting with '@' as an expression - including JSON property
                            // NAMES, not just values. A literal '@odata.type' key (needed here
                            // because Microsoft Graph's callback body requires it) must escape
                            // the leading '@' by doubling it to '@@', otherwise ARM's template
                            // validator tries to parse 'odata.type' as a function call and
                            // fails with "expected token 'LeftParenthesis' and actual 'Dot'".
                            '@@odata.type': 'microsoft.graph.accessPackageAssignmentRequestCallbackData'
                            customExtensionStageInstanceId: '@{triggerBody()?[\'CustomExtensionStageInstanceId\']}'
                            customExtensionStageInstanceDetail: '@{concat(\'DL provisioning: \', body(\'Parse_Function_Response\')?[\'OverallStatus\'])}'
                          }
                        }
                        authentication: {
                          type: 'ManagedServiceIdentity'
                          identity: '@parameters(\'userAssignedIdentityResourceId\')'
                          audience: 'https://graph.microsoft.com'
                        }
                      }
                    }
                  }
                  else: {
                    actions: {}
                  }
                }
              }
              else: {
                actions: {}
              }
            }
          }
          else: {
            actions: {}
          }
        }
      }
      outputs: {}
    }
    parameters: {
      accessPackageCatalogId: {
        value: accessPackageCatalogId
      }
      distributionListMapping: {
        value: distributionListMapping
      }
      functionUri: {
        value: functionUri
      }
      functionAudience: {
        value: functionAudience
      }
      userAssignedIdentityResourceId: {
        value: userAssignedIdentityResourceId
      }
      callbackSourceName: {
        value: callbackSourceName
      }
    }
  }
}

output logicAppResourceId string = logicApp.id
