// src/lib/keycloak.ts
import Keycloak from 'keycloak-js';

const keycloak = new Keycloak({
  url: 'https://login.opencrvs.ktsang.com/auth',
  realm: 'opencrvs',
  clientId: 'opencrvs-web',
});

export default keycloak;
