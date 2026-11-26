//! The server's side of activitykit's pushes, as an example: builds a payload with `activitykit::push` and sends it to
//! APNs over HTTP/2, signed with a token of the team's APNs key (ES256). activitykit holds no key and sends nothing;
//! this is what a server adds.
//!
//! ```text
//! apns-sender update <revision> '<values as JSON>'    to an activity's push token
//! apns-sender end [<revision> '<values as JSON>']     to an activity's push token
//! apns-sender start <key> '<values as JSON>'          to the app's push-to-start token (iOS 17.2)
//! ```
//!
//! The environment names the rest: `APNS_KEY` (the path of the `.p8` file), `APNS_KEY_ID`, `APNS_TEAM_ID`,
//! `APNS_BUNDLE_ID` (the app's), `APNS_TOKEN` (the hex token the app got in `Event::PushToken` or
//! `Event::PushToStartToken`) and `APNS_HOST` (default `api.sandbox.push.apple.com`, for development builds; production
//! is `api.push.apple.com`). The key never leaves this process: keep the `.p8` file out of any repository.

use activitykit::layout::text;
use activitykit::push::{PRIORITY_NOW, PUSH_TYPE, Payload, topic};
use activitykit::{Alert, Bound, Layout, Values};
use jsonwebtoken::{Algorithm, EncodingKey, Header};
use serde::Serialize;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

type Failure = Box<dyn std::error::Error>;

/// The claims of an APNs provider token: the team, and when it was made.
#[derive(Serialize)]
struct Claims {
    iss: String,
    iat: u64,
}

fn env(name: &str) -> Result<String, Failure> {
    std::env::var(name).map_err(|_| format!("{name} is not set").into())
}

/// A provider token, valid for an hour: APNs refuses one older and asks that it be made at most every 20 minutes.
fn provider_token() -> Result<String, Failure> {
    let pem = std::fs::read(env("APNS_KEY")?)?;
    let mut header = Header::new(Algorithm::ES256);
    header.kid = Some(env("APNS_KEY_ID")?);
    let claims = Claims {
        iss: env("APNS_TEAM_ID")?,
        iat: SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs(),
    };
    Ok(jsonwebtoken::encode(
        &header,
        &claims,
        &EncodingKey::from_ec_pem(&pem)?,
    )?)
}

/// The payload that the arguments ask for.
fn payload(arguments: &[String]) -> Result<Payload, Failure> {
    let values = |at: usize| -> Result<Values, Failure> {
        let json = arguments.get(at).ok_or("the values are missing")?;
        Ok(serde_json::from_str(json)?)
    };
    let revision = |at: usize| -> Result<u64, Failure> {
        Ok(arguments
            .get(at)
            .ok_or("the revision is missing")?
            .parse()?)
    };
    match arguments.first().map(String::as_str) {
        Some("update") => Ok(Payload::update(values(2)?).revision(revision(1)?)),
        Some("end") if arguments.len() > 1 => Ok(Payload::end_with(values(2)?).revision(revision(1)?)),
        Some("end") => Ok(Payload::end()),
        Some("start") => {
            let key = arguments.get(1).ok_or("the key is missing")?;
            let id = format!("apns-sender-{}", SystemTime::now().duration_since(UNIX_EPOCH)?.as_millis());
            let layout = Layout::new(text(Bound::key("status")));
            Ok(Payload::start(id, key.as_str(), layout, values(2)?).alert(Alert::new("Started", "By a push")))
        }
        _ => Err("usage: apns-sender update <revision> '<values>' | end [<revision> '<values>'] | start <key> '<values>'".into()),
    }
}

#[tokio::main]
async fn main() -> Result<(), Failure> {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let body = payload(&arguments)?.to_json()?;
    let host =
        std::env::var("APNS_HOST").unwrap_or_else(|_| "api.sandbox.push.apple.com".to_owned());
    let url = format!("https://{host}/3/device/{}", env("APNS_TOKEN")?);
    let client = reqwest::Client::builder()
        .http2_prior_knowledge()
        .timeout(Duration::from_secs(30))
        .build()?;
    let response = client
        .post(url)
        .header("authorization", format!("bearer {}", provider_token()?))
        .header("apns-push-type", PUSH_TYPE)
        .header("apns-topic", topic(&env("APNS_BUNDLE_ID")?))
        .header("apns-priority", PRIORITY_NOW.to_string())
        .header("content-type", "application/json")
        .body(body.clone())
        .send()
        .await?;
    let status = response.status();
    let apns_id = response
        .headers()
        .get("apns-id")
        .and_then(|id| id.to_str().ok())
        .unwrap_or("-")
        .to_owned();
    let answer = response.text().await?;
    println!("sent {body}");
    println!("APNs {status} apns-id {apns_id} {answer}");
    if status.is_success() {
        Ok(())
    } else {
        Err(format!("APNs answered {status}").into())
    }
}
