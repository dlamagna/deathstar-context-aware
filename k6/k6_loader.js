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

export const options = {
    stages: [
      { duration: '1m', target: 150 },
      { duration: '13m', target: 180},
      { duration: '1m', target: 1 },
    ],
};

const nginx_host = '147.83.130.183:32000';//'147.83.130.67:30177'
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
        timeout: '1s',  // Add 1 second timeout here
    };

    let res = http.post(baseURL, body, params);

    check(res, {
        'is status 200': (r) => r.status === 200,
    });
}