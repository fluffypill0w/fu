use std::{
    env, process,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    thread,
};

use alloy::primitives::{address, b256, hex, keccak256, Address, B256};

const DEPLOYER: Address = address!("4e59b44847b379578588920cA78FbF26c0B4956C");
const UNISWAP_FACTORY: Address = address!("5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f");
const WETH: Address = address!("C02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2");
const UNISWAP_PAIR_INITCODE_HASH: B256 =
    b256!("96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f");
const N_THREADS: usize = 4;

fn has_leading_zero_bits(addr: Address, leading_zero_bits: usize) -> bool {
    let bytes = addr.as_slice(); // 20 bytes
    let mut remaining = leading_zero_bits;

    for b in bytes {
        let zeroes_in_byte = b.leading_zeros() as usize;
        if zeroes_in_byte == 8 {
            if remaining > 8 {
                remaining -= 8;
            } else {
                return remaining == 8;
            }
        } else {
            return zeroes_in_byte == remaining;
        }
    }
    remaining == 0
}

#[repr(C)]
struct B256Aligned(B256, [usize; 0]);

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = env::args().collect();
    if args.len() != 3 {
        eprintln!(
            "Usage: {} <token_initcode_hash> <leading_zero_bits>",
            args[0]
        );
        eprintln!("Example:");
        eprintln!("  {} 8f5e... (32-byte hex) 16", args[0]);
        process::exit(1);
    }

    let token_initcode: B256 = hex::FromHex::from_hex(args[1].trim_start_matches("0x"))?;

    let leading_zero_bits: usize = args[2].parse().expect("invalid integer for bits");

    // We'll store the final result in a shared "once" slot
    // so that whichever thread finds the solution can store it
    // and others can stop.
    let found_flag = Arc::new(AtomicBool::new(false));
    let result_salt = Arc::new(Mutex::new(None::<B256>));
    let result_token_address = Arc::new(Mutex::new(None::<Address>));
    let result_pair_address = Arc::new(Mutex::new(None::<Address>));

    let mut handles = Vec::with_capacity(N_THREADS);

    for thread_idx in 0..N_THREADS {
        let found_flag = Arc::clone(&found_flag);
        let result_salt = Arc::clone(&result_salt);
        let result_token_address = Arc::clone(&result_token_address);
        let result_pair_address = Arc::clone(&result_pair_address);

        let handle = thread::spawn(move || {
            let mut salt = B256Aligned(B256::ZERO, []);
            // SAFETY: B256 is aligned enough to treat the last 8 bytes as a `usize`.
            let salt_word = unsafe {
                &mut *salt
                    .0
                    .as_mut_ptr()
                    .add(32 - std::mem::size_of::<usize>())
                    .cast::<usize>()
            };

            *salt_word = thread_idx;

            while !found_flag.load(Ordering::Relaxed) {
                let token_address = DEPLOYER.create2(salt.0, token_initcode);

                let (token0, token1) = if token_address < WETH {
                    (token_address, WETH)
                } else {
                    (WETH, token_address)
                };

                let mut pair_salt_input = [0u8; 40];
                pair_salt_input[0..20].copy_from_slice(token0.as_slice());
                pair_salt_input[20..40].copy_from_slice(token1.as_slice());
                let pair_salt = keccak256(&pair_salt_input);

                let pair_address = UNISWAP_FACTORY.create2(pair_salt, UNISWAP_PAIR_INITCODE_HASH);

                if has_leading_zero_bits(pair_address, leading_zero_bits) {
                    if !found_flag.swap(true, Ordering::Relaxed) {
                        let mut lock_salt = result_salt.lock().unwrap();
                        *lock_salt = Some(salt.0);

                        let mut lock_token = result_token_address.lock().unwrap();
                        *lock_token = Some(token_address);

                        let mut lock_pair = result_pair_address.lock().unwrap();
                        *lock_pair = Some(pair_address);
                    }
                    break;
                }

                *salt_word = salt_word.wrapping_add(N_THREADS);
            }
        });

        handles.push(handle);
    }

    for h in handles {
        let _ = h.join();
    }

    let salt_opt = result_salt.lock().unwrap();
    if let Some(salt) = *salt_opt {
        let token_address = result_token_address.lock().unwrap().unwrap();
        let pair_address = result_pair_address.lock().unwrap().unwrap();

        println!("\nSuccess!");
        println!("Required leading zero bits: {leading_zero_bits}");
        println!("Salt (hex):    {salt}");
        println!("Token Address: {token_address}");
        println!("Pair Address:  {pair_address}");
    } else {
        println!("No salt found (this would only happen if you had a break condition).");
    }

    Ok(())
}