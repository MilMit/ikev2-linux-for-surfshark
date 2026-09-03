#!/usr/bin/env python3
"""Split tunneling policy model."""
import json,sys

policy={
 'route_all': True,
 'applications': [],
 'domains': [],
 'cidr_exceptions': []
}

print(json.dumps(policy,indent=2))
