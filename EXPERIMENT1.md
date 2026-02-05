1. Ingress gateway sets x-caller-type: principal                                              
2. Agent sidecars read x-caller-type to determine hop_kind, set x-caller-type: agent on       
  outbound calls                                                                                
3. Span attributes:                                                                           
    - trust.principal_id = user:                                                                
    - trust.run_id =                                                                            
    - trust.hop_kind = principal_to_agent | agent_to_agent | agent_to_resource                  
    - trust.target = agent: | resource: 