#!/usr/bin/env python3

import boto3
import sys
import pathlib
import argparse
import os
from typing import List
import time
import socket

# -----------------------------
# PARAMÈTRES & ENV
# -----------------------------

ENV_FILE = os.getenv("ENV_FILE", ".env")

def _read_dotenv(path: str) -> dict:
    vals = {}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                s = line.strip()
                if not s or s.startswith("#") or "=" not in s:
                    continue
                k, v = s.split("=", 1)
                vals[k.strip()] = v.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return vals

_cfg = {**_read_dotenv(ENV_FILE), **os.environ}

AWS_REGION = _cfg.get("AWS_REGION", "us-east-1")
AZ = _cfg.get("AWS_AZ", "us-east-1a")
KEY_NAME = _cfg.get("KEY_NAME", "cle_log8415e")
AWS_ACCESS_KEY_ID = _cfg.get("aws_access_key_id")
AWS_SECRET_ACCESS_KEY = _cfg.get("aws_secret_access_key")
AWS_SESSION_TOKEN = _cfg.get("aws_session_token")

INSTANCE_TYPE_GATEKEEPER = "t2.large"
INSTANCE_TYPE_PROXY = "t2.large"
INSTANCE_TYPE_DB = "t2.micro"

UBUNTU_AMI = _cfg.get("UBUNTU_AMI", "ami-0ecb62995f68bb549")  
NUM_DB_WORKERS = 2

session = boto3.Session(
    aws_access_key_id=AWS_ACCESS_KEY_ID,
    aws_secret_access_key=AWS_SECRET_ACCESS_KEY,
    aws_session_token=AWS_SESSION_TOKEN,
    region_name=AWS_REGION,
)

ec2 = session.resource("ec2", region_name=AWS_REGION)
ec2_client = session.client("ec2", region_name=AWS_REGION)


# ----------------------------------------
# UTILS
# ----------------------------------------

def load_file(path: str) -> str:
    with open(path, "r") as f:
        return f.read()

def save_ids(data: dict) -> None:
    """Save network IDs to .env file."""
    env_path = pathlib.Path(ENV_FILE)

    # Read existing .env content
    existing_lines = []
    if env_path.exists():
        with open(env_path, "r", encoding="utf-8") as f:
            existing_lines = [line.rstrip() for line in f.readlines()]

    # Remove old network ID entries if they exist
    keys_to_save = set(data.keys())
    filtered_lines = [
        line for line in existing_lines
        if not any(line.startswith(f"{key}=") for key in keys_to_save)
    ]

    # Append new IDs
    with open(env_path, "w", encoding="utf-8") as f:
        for line in filtered_lines:
            f.write(line + "\n")
        for key, value in data.items():
            f.write(f"{key}={value}\n")

    print(f"[INFO] Saved network IDs to {ENV_FILE}")

def load_ids() -> dict:
    """Load network IDs from .env file."""
    cfg = {**_read_dotenv(ENV_FILE), **os.environ}

    required_keys = [
        "VPC_ID", "PUBLIC_SUBNET_ID", "PRIVATE_PROXY_SUBNET_ID",
        "PRIVATE_DB_SUBNET_ID", "SG_GATEKEEPER_ID", "SG_PROXY_ID", "SG_DB_ID"
    ]

    missing = [k for k in required_keys if k not in cfg]
    if missing:
        raise RuntimeError(
            f"Missing network IDs in {ENV_FILE}: {', '.join(missing)}. "
            "Run: python VPC_architecture.py create"
        )

    return {k: cfg[k] for k in required_keys}

def wait_for_master_simple(host="10.0.3.10", sleep_s=120) -> None:
    
    print("[WAIT] Waiting for MySQL port on master")
    start = time.time()
    while time.time() - start < 300:
        try:
            with socket.create_connection((host, 3306), timeout=3):
                break
        except OSError:
            time.sleep(5)

    # 2) temporisateur fixe
    print(f"[WAIT] Sleeping {sleep_s}s to let sakila import finish")
    time.sleep(sleep_s)
    
# ----------------------------------------
# NETWORK CREATION
# ----------------------------------------

def create_vpc():
    print("[STEP] Creating VPC...")
    vpc = ec2.create_vpc(CidrBlock="10.0.0.0/16")
    vpc.wait_until_available()

    vpc.modify_attribute(EnableDnsSupport={"Value": True})
    vpc.modify_attribute(EnableDnsHostnames={"Value": True})
    vpc.create_tags(Tags=[{"Key": "Name", "Value": "NNEME-LOG8415E-VPC"}])

    print(f"VPC created: {vpc.id}")
    return vpc

def create_subnets(vpc):
    print("Creating subnets...")

    public_gatekeeper_subnet = vpc.create_subnet(
        CidrBlock="10.0.1.0/24",
        AvailabilityZone=AZ,
    )
    ec2_client.modify_subnet_attribute(
    SubnetId=public_gatekeeper_subnet.id,
    MapPublicIpOnLaunch={"Value": True},
    )
    public_gatekeeper_subnet.create_tags(
        Tags=[{"Key": "Name", "Value": "NNEME-Public-Subnet"}]
    )

    private_proxy_subnet = vpc.create_subnet(
        CidrBlock="10.0.2.0/24",
        AvailabilityZone=AZ,
    )
    private_proxy_subnet.create_tags(
        Tags=[{"Key": "Name", "Value": "NNEME-Private-Proxy-Subnet"}]
    )

    private_db_subnet = vpc.create_subnet(
        CidrBlock="10.0.3.0/24",
        AvailabilityZone=AZ,
    )
    private_db_subnet.create_tags(
        Tags=[{"Key": "Name", "Value": "NNEME-Private-DB-Subnet"}]
    )

    print(
        f"[OK] Subnets created: "
        f"{public_gatekeeper_subnet.id}, {private_proxy_subnet.id}, {private_db_subnet.id}"
    )
    return public_gatekeeper_subnet, private_proxy_subnet, private_db_subnet

def create_igw_and_routes(vpc, public_gatekeeper_subnet):
    print("[STEP] Creating Internet Gateway + public route table...")
    igw = ec2.create_internet_gateway()
    igw.attach_to_vpc(VpcId=vpc.id)
    igw.create_tags(Tags=[{"Key": "Name", "Value": "NNEME-LOG8415E-IGW"}])

    public_rt = vpc.create_route_table()
    public_rt.create_tags(Tags=[{"Key": "Name", "Value": "NNEME-Public-RT"}])
    public_rt.associate_with_subnet(SubnetId=public_gatekeeper_subnet.id)
    public_rt.create_route(
        DestinationCidrBlock="0.0.0.0/0",
        GatewayId=igw.id,
    )

    print("[OK] IGW and public route table created")
    return igw, public_rt

def create_nat_and_private_rt(vpc, public_gatekeeper_subnet, private_proxy_subnet, private_db_subnet):
    print("[STEP] Creating NAT Gateway + private route table...")

    eip_alloc = ec2_client.allocate_address(Domain="vpc")
    eip_allocation_id = eip_alloc["AllocationId"]

    nat_gw_resp = ec2_client.create_nat_gateway(
        SubnetId=public_gatekeeper_subnet.id,
        AllocationId=eip_allocation_id,
        TagSpecifications=[
            {
                "ResourceType": "natgateway",
                "Tags": [{"Key": "Name", "Value": "NNEME-LOG8415E-NAT"}],
            }
        ],
    )
    nat_gw_id = nat_gw_resp["NatGateway"]["NatGatewayId"]
    print(f"[INFO] NAT Gateway creating: {nat_gw_id}")

    waiter = ec2_client.get_waiter("nat_gateway_available")
    waiter.wait(NatGatewayIds=[nat_gw_id])
    print(f"[OK] NAT Gateway ready: {nat_gw_id}")

    private_nat_rt = vpc.create_route_table()
    private_nat_rt.create_tags(Tags=[{"Key": "Name", "Value": "NNEME-Private-RT"}])

    private_nat_rt.associate_with_subnet(SubnetId=private_proxy_subnet.id)
    private_nat_rt.associate_with_subnet(SubnetId=private_db_subnet.id)

    private_nat_rt.create_route(
        DestinationCidrBlock="0.0.0.0/0",
        NatGatewayId=nat_gw_id,
    )

    print("[OK] Private route table for proxy + db created")
    return nat_gw_id, private_nat_rt

def create_security_groups(vpc):
    print("[STEP] Creating Security Groups")

    # Gatekeeper SG
    sg_gatekeeper = ec2.create_security_group(
        GroupName="SG_Gatekeeper",
        Description="Gatekeeper public SG",
        VpcId=vpc.id,
    )
    sg_gatekeeper.create_tags(
        Tags=[{"Key": "Name", "Value": "NNEME-SG_Gatekeeper"}]
    )

    sg_gatekeeper.authorize_ingress(
        IpPermissions=[
            {   # HTTP
                "IpProtocol": "tcp",
                "FromPort": 8080,
                "ToPort": 8080,
                "IpRanges": [{"CidrIp": "0.0.0.0/0"}],
            },
            {   # SSH (à restreindre à ton IP si tu veux)
                "IpProtocol": "tcp",
                "FromPort": 22,
                "ToPort": 22,
                "IpRanges": [{"CidrIp": "0.0.0.0/0"}],
            },
        ]
    )

    # Proxy SG
    sg_proxy = ec2.create_security_group(
        GroupName="SG_Proxy",
        Description="Proxy SG (trusted host)",
        VpcId=vpc.id,
    )
    sg_proxy.create_tags(Tags=[{"Key": "Name", "Value": "NNEME-SG_Proxy"}])

    sg_proxy.authorize_ingress(
        IpPermissions=[
            {   # From Gatekeeper to Proxy (Flask port 5000)
                "IpProtocol": "tcp",
                "FromPort": 5000,
                "ToPort": 5000,
                "UserIdGroupPairs": [{"GroupId": sg_gatekeeper.id}],
            },
            {   # SSH debug from Gatekeeper
                "IpProtocol": "tcp",
                "FromPort": 22,
                "ToPort": 22,
                "UserIdGroupPairs": [{"GroupId": sg_gatekeeper.id}],
            },
        ]
    )

    # DB SG
    sg_db = ec2.create_security_group(
        GroupName="SG_DB",
        Description="DB SG (MySQL cluster)",
        VpcId=vpc.id,
    )
    sg_db.create_tags(Tags=[{"Key": "Name", "Value": "NNEME-SG_DB"}])

    sg_db.authorize_ingress(
        IpPermissions=[
            {   # MySQL from Proxy + DB<->DB for replication
                "IpProtocol": "tcp",
                "FromPort": 3306,
                "ToPort": 3306,
                "UserIdGroupPairs": [
                    {"GroupId": sg_proxy.id},
                    {"GroupId": sg_db.id},
                ],
            },
            {   # SSH from Gatekeeper as bastion
                "IpProtocol": "tcp",
                "FromPort": 22,
                "ToPort": 22,
                "UserIdGroupPairs": [{"GroupId": sg_gatekeeper.id}],
            },
        ]
    )

    print(f"[OK] SGs created: {sg_gatekeeper.id}, {sg_proxy.id}, {sg_db.id}")
    return sg_gatekeeper, sg_proxy, sg_db


# ----------------------------------------
# EC2 CREATION
# ----------------------------------------

def launch_instances(
    public_gatekeeper_subnet,
    private_proxy_subnet,
    private_db_subnet,
    sg_gatekeeper,
    sg_proxy,
    sg_db,
):

    gatekeeper_user_data = load_file("user_data/gatekeeper_setup.sh")
    proxy_user_data = load_file("user_data/proxy_setup.sh")
    db_manager_data = load_file("user_data/db_manager_setup.sh")
    db_worker_ud = load_file("user_data/db_worker_setup.sh")
    bench_ud = load_file("user_data/sysbench_setup.sh")

    print("Launching Gatekeeper EC2")
    gatekeeper = ec2.create_instances(
        ImageId=UBUNTU_AMI,
        InstanceType=INSTANCE_TYPE_GATEKEEPER,
        KeyName=KEY_NAME,
        MinCount=1,
        MaxCount=1,
        NetworkInterfaces=[{
            "SubnetId": public_gatekeeper_subnet.id,
            "DeviceIndex": 0,
            "AssociatePublicIpAddress": True,
            "Groups": [sg_gatekeeper.id],
        }],
        UserData=gatekeeper_user_data,
        TagSpecifications=[{
            "ResourceType": "instance",
            "Tags": [{"Key": "Name", "Value": "Gatekeeper-EC2"}],
        }],
    )[0]

    print("Launching Proxy EC2")
    proxy = ec2.create_instances(
        ImageId=UBUNTU_AMI,
        InstanceType=INSTANCE_TYPE_PROXY,
        KeyName=KEY_NAME,
        MinCount=1,
        MaxCount=1,
        NetworkInterfaces=[{
            "SubnetId": private_proxy_subnet.id,
            "DeviceIndex": 0,
            "AssociatePublicIpAddress": False,
            "Groups": [sg_proxy.id],
        "PrivateIpAddress": "10.0.2.15",
        }],
        UserData=proxy_user_data,
        TagSpecifications=[{
            "ResourceType": "instance",
            "Tags": [{"Key": "Name", "Value": "Proxy-EC2"}],
        }],
    )[0]

    print("Launching DB Manager EC2")
    manager = ec2.create_instances(
        ImageId=UBUNTU_AMI,
        InstanceType=INSTANCE_TYPE_DB,
        KeyName=KEY_NAME,
        MinCount=1,
        MaxCount=1,
        NetworkInterfaces=[{
            "SubnetId": private_db_subnet.id,
            "DeviceIndex": 0,
            "AssociatePublicIpAddress": False,
            "Groups": [sg_db.id],
        "PrivateIpAddress": "10.0.3.10",
        }],
        UserData=db_manager_data,  # manager user-data doit gérer le rôle master
        TagSpecifications=[{
            "ResourceType": "instance",
            "Tags": [
                {"Key": "Name", "Value": "DB-Manager"},
                {"Key": "Role", "Value": "manager"},
                ],
        }],
    )[0]
    
    # Wait instance is fully up
    manager.wait_until_running()
    ec2_client.get_waiter("instance_status_ok").wait(InstanceIds=[manager.id])

    print("[INFO] Waiting before launching workers (simple sleep)")
    wait_for_master_simple(host="10.0.3.10", sleep_s=300)
    
    print(f"Lauching {NUM_DB_WORKERS} DB Worker EC2 instances")

    # Fixed private IPs (must be inside 10.0.3.0/24 and unused)
    worker_ips = ["10.0.3.11", "10.0.3.12"]

    if NUM_DB_WORKERS != len(worker_ips):
        raise RuntimeError(
            f"NUM_DB_WORKERS={NUM_DB_WORKERS} but worker_ips has {len(worker_ips)} entries. "
            "Update worker_ips to match NUM_DB_WORKERS."
        )

    workers = []
    for idx, ip in enumerate(worker_ips, start=1):
        w = ec2.create_instances(
            ImageId=UBUNTU_AMI,
            InstanceType=INSTANCE_TYPE_DB,
            KeyName=KEY_NAME,
            MinCount=1,
            MaxCount=1,
            NetworkInterfaces=[{
                "SubnetId": private_db_subnet.id,
                "DeviceIndex": 0,
                "AssociatePublicIpAddress": False,
                "Groups": [sg_db.id],
                "PrivateIpAddress": ip,
            }],
            UserData=db_worker_ud,
            TagSpecifications=[{
                "ResourceType": "instance",
                "Tags": [
                    {"Key": "Name", "Value": f"DB-Worker-{idx}"},
                    {"Key": "Role", "Value": "worker"},
                ]
            }],
        )[0]
        workers.append(w)
    
    print("[INFO] Waiting before launching sysbench_benchmark")
    wait_for_master_simple(host="10.0.3.12", sleep_s=180)
    
    print("Launching Benchmark EC2 (private, in proxy subnet)")
    benchmark = ec2.create_instances(
        ImageId=UBUNTU_AMI,
        InstanceType="t3.micro",
        KeyName=KEY_NAME,
        MinCount=1,
        MaxCount=1,
        NetworkInterfaces=[{
            "SubnetId": private_proxy_subnet.id,   
            "DeviceIndex": 0,
            "AssociatePublicIpAddress": False,
            "Groups": [sg_proxy.id],               
        }],
        UserData=bench_ud,
        TagSpecifications=[{
            "ResourceType": "instance",
            "Tags": [{"Key": "Name", "Value": "Benchmark-EC2"}],
        }],
    )[0]

    print("  Instances launched:")
    print("  Gatekeeper:", gatekeeper.id)
    print("  Proxy     :", proxy.id)
    print("  DB Manager:", manager.id)
    print("  DB Workers:", [w.id for w in workers])
    print("  Benchmark :", benchmark.id)
    


# ============================================================
# CLI Commands
# ============================================================

def cmd_create_vpc(args):
    """Create full network & save IDs."""
    vpc = create_vpc()
    public_subnet, private_proxy_subnet, private_db_subnet = create_subnets(vpc)
    igw, public_rt = create_igw_and_routes(vpc, public_subnet)
    nat_id, private_rt = create_nat_and_private_rt(
        vpc, public_subnet, private_proxy_subnet, private_db_subnet
    )
    sg_gatekeeper, sg_proxy, sg_db = create_security_groups(vpc)

    ids = {
        "VPC_ID": vpc.id,
        "PUBLIC_SUBNET_ID": public_subnet.id,
        "PRIVATE_PROXY_SUBNET_ID": private_proxy_subnet.id,
        "PRIVATE_DB_SUBNET_ID": private_db_subnet.id,
        "SG_GATEKEEPER_ID": sg_gatekeeper.id,
        "SG_PROXY_ID": sg_proxy.id,
        "SG_DB_ID": sg_db.id,
    }
    save_ids(ids)
    return 0

def cmd_create_ec2(args):
    """Create EC2 instances using existing network."""
    ids = load_ids()

    vpc = ec2.Vpc(ids["VPC_ID"])
    public_subnet = ec2.Subnet(ids["PUBLIC_SUBNET_ID"])
    private_proxy_subnet = ec2.Subnet(ids["PRIVATE_PROXY_SUBNET_ID"])
    private_db_subnet = ec2.Subnet(ids["PRIVATE_DB_SUBNET_ID"])

    sg_gatekeeper = ec2.SecurityGroup(ids["SG_GATEKEEPER_ID"])
    sg_proxy = ec2.SecurityGroup(ids["SG_PROXY_ID"])
    sg_db = ec2.SecurityGroup(ids["SG_DB_ID"])

    launch_instances(
        public_subnet,
        private_proxy_subnet,
        private_db_subnet,
        sg_gatekeeper,
        sg_proxy,
        sg_db,
    )
    return 0

def cmd_destroy(args):
    """Destroy all EC2 instances + VPC + subnets + NAT + IGW + SG."""

    cfg = {**_read_dotenv(ENV_FILE), **os.environ}

    vpc_id = cfg.get("VPC_ID")
    if not vpc_id:
        print("VPC_ID not found in .env")
        return 1

    print(f"Destroying VPC architecture: {vpc_id}")
    vpc = ec2.Vpc(vpc_id)

    # ================================
    # 1. TERMINATE EC2 INSTANCES
    # ================================
    print("Terminating EC2 instances...")
    instances = list(vpc.instances.all())
    instance_ids = [i.id for i in instances]
    if instance_ids:
        print(f"Terminating: {instance_ids}")
        ec2_client.terminate_instances(InstanceIds=instance_ids)
        ec2_client.get_waiter("instance_terminated").wait(InstanceIds=instance_ids)
    else:
        print("No EC2 instances found.")

    # ================================
    # 2. DELETE NAT Gateway
    # ================================
    print("Deleting NAT Gateways...")

    nat_gws = ec2_client.describe_nat_gateways(
        Filter=[{"Name": "vpc-id", "Values": [vpc_id]}]
    )["NatGateways"]

    for ng in nat_gws:
        ng_id = ng["NatGatewayId"]
        print(f"Deleting NAT: {ng_id}")
        ec2_client.delete_nat_gateway(NatGatewayId=ng_id)

        # Wait for deletion
        waiter = ec2_client.get_waiter("nat_gateway_deleted")
        waiter.wait(NatGatewayIds=[ng_id])

        # Release Elastic IP
        for addr in ng.get("NatGatewayAddresses", []):
            alloc_id = addr.get("AllocationId")
            if alloc_id:
                print(f"Releasing Elastic IP: {alloc_id}")
                ec2_client.release_address(AllocationId=alloc_id)

    # ================================
    # 3. DETACH & DELETE INTERNET GATEWAY
    # ================================
    print("Removing Internet Gateways")
    igws = list(vpc.internet_gateways.all())
    for igw in igws:
        print(f"Detaching & deleting IGW {igw.id}")
        igw.detach_from_vpc(VpcId=vpc_id)
        igw.delete()

    # ================================
    # 4. DELETE ROUTE TABLES
    # ================================
    print("Deleting route tables...")
    for rt in vpc.route_tables.all():
        # skip main route table automatically created by AWS
        associations = rt.associations_attribute
        is_main = any(a.get("Main") for a in associations)
        if is_main:
            continue

        print(f"Deleting route table: {rt.id}")
        rt.delete()

    # ================================
    # 5. DELETE SUBNETS
    # ================================
    print("Deleting subnets...")
    for subnet in vpc.subnets.all():
        print(f"Deleting subnet: {subnet.id}")
        subnet.delete()

    # ================================
    # 6. DELETE SECURITY GROUPS
    # ================================
    print("Deleting security groups...")
    for sg in vpc.security_groups.all():
        if sg.group_name == "default":
            continue
        print(f"Deleting SG: {sg.id}")
        ec2_client.delete_security_group(GroupId=sg.id)

    # ================================
    # 7. DELETE VPC
    # ================================
    print("Deleting VPC...")
    vpc.delete()
    print("VPC deleted successfully.")

    return 0

# ============================================================
# Entry Point
# ============================================================

def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(
        description="LOG8415E - VPC + EC2 Gatekeeper/Proxy/DB automation"
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("create", help="Create VPC, subnets, routes, SG and save IDs")
    sub.add_parser("deploy", help="Create EC2 instances (Gatekeeper, Proxy, DB) using saved network")
    sub.add_parser("destroy", help="Destroy resources ")

    args = parser.parse_args(argv)

    try:
        if args.cmd == "create":
            return cmd_create_vpc(args)
        elif args.cmd == "deploy":
            return cmd_create_ec2(args)
        elif args.cmd == "destroy":
            return cmd_destroy(args)
        else:
            parser.print_help()
            return 2
    except Exception as e:
        print(f"[ERROR] {e}")
        return 1

if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))