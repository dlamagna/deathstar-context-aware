import http from 'k6/http';
import { check } from 'k6';
import { randomIntBetween, randomString } from 'https://jslib.k6.io/k6-utils/1.4.0/index.js';

// export let options = {
//     scenarios: {
//         constant_rps: {
//             executor: 'constant-arrival-rate',
//             rate: 10,  // 10 requests per second
//             timeUnit: '1s',
//             duration: '300s',
//             preAllocatedVUs: 20, // Pre-allocate enough VUs
//             //maxVUs: 10,
//         },
//     },
// };

const STAGE_TARGET = Number(__ENV.K6_TARGET || 40);
const STAGE_DURATION = __ENV.K6_DURATION || '10m';
const REQUEST_TIMEOUT = __ENV.K6_TIMEOUT || '5s';

export const options = {
    // 'vus' sets the maximum number of VUs k6 is allowed to run.
    // Without this, older k6 versions cap at 1 VU even if stages
    // request a higher target.
    vus: STAGE_TARGET,
    stages: [
        { duration: '30s', target: Math.floor(STAGE_TARGET * 0.6) },
        { duration: '30s', target: Math.floor(STAGE_TARGET * 0.9) },
        { duration: STAGE_DURATION, target: STAGE_TARGET },
        { duration: '1m', target: 1 },
    ],
};

const nginx_host = __ENV.NGINX_HOST || '172.18.0.2:31031'; //'147.83.130.67:30177'
const baseURL = `http://${nginx_host}/wrk2-api/post/compose`;

function generatePostData(userIndex) {
    let text = randomString(256);
    let userMention = `@username_${randomIntBetween(1, 1000)}`;
    let url = `http://${randomString(10)}.com`;

    let postData = {
        username: `username_${userIndex}`,
        user_id: userIndex,
        text: `${text} ${userMention} ${url}`,
        media_ids: `["123456789012345678"]`,
        media_types: `["png"]`,
        post_type: 0
    };

    return Object.keys(postData)
        .map((key) => `${encodeURIComponent(key)}=${encodeURIComponent(postData[key])}`)
        .join('&');
}

export default function () {
    let userIndex = randomIntBetween(1, 1000);
    let body = generatePostData(userIndex);

    let params = {
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        timeout: REQUEST_TIMEOUT,  // Configurable timeout via K6_TIMEOUT environment variable
    };

    let res = http.post(baseURL, body, params);

    check(res, {
        'is status 200': (r) => r.status === 200,
    });
}
