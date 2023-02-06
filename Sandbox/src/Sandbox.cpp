#include "Sandbox.h"
#include "Sapfire/renderer/Mesh.h"
#include <imgui.h>
#include <glfw/include/GLFW/glfw3.h>

const std::string SHADER_PATH = "Shaders/Sprite.glsl";
const std::string SHADER_NAME = "Sprite";

SandboxLayer::SandboxLayer()
    : /* mCamera(1.6f, -1.6f, 0.9f, -0.9) */
      mCamera(70.f, 1280, 720, 0, 2000), mDirection(glm::vec3(0))
{
	mVA.reset(VertexArray::Create());
	float vertices[7 * 4] = {
	    -0.5f, 0.5f,  0.f, 0.f, 1.f, // top left
	    0.5f,  0.5f,  0.f, 1.f, 1.f, // top right
	    0.5f,  -0.5f, 0.f, 1.f, 0.f, // bottom right
	    -0.5f, -0.5f, 0.f, 0.f, 0.f	 // bottom left
	};

	uint32_t indices[] = {0, 1, 2, 2, 3, 0};
	BufferLayout layout = {{"inPosition", ShaderDataType::Vec3}, {"inTexCoord", ShaderDataType::Vec2}};
	Ref<VertexBuffer> vb;
	vb = VertexBuffer::Create();
	vb->SetLayout(layout);
	vb->SetData(vertices, sizeof(vertices));
	mVA->AddVertexBuffer(vb);
	Ref<IndexBuffer> ib;
	ib = IndexBuffer::Create();
	ib->SetData(indices, sizeof(indices));
	mVA->AddIndexBuffer(ib);
	mSpriteShader = mShaderLibrary.Load(SHADER_PATH);
	mTexture = Texture::Create("Assets/Asteroid.png");
	mSpriteShader->SetIntUniform("uTexture", mTexture->GetID());
	mCamera.SetPosition(glm::vec3(0.f));
	mMeshShader = mShaderLibrary.Load("Shaders/BasicMesh.glsl");
	mSphereMesh = CreateRef<Mesh>("Assets/Sphere.blend1");
	mSphereMesh->SetTexture("Assets/Farback01.png");
	mSphereMesh->SetPosition(glm::vec3({0.f, 0.f, 0.4f}));
	mSphereMesh->SetScale(glm::vec3(1.f));
	mCameraRotation = 0.f;
}

static glm::vec4 clearColor(0.1f, 0.1f, 0.1f, 1);
static glm::vec3 scale(1.f);

const float MOVE_SPEED = 0.1f;

void SandboxLayer::OnUpdate(float deltaTime)
{
	//mCameraRotation += 30.f * deltaTime;
	auto pos = mCamera.GetPosition();
	mCamera.SetPosition(pos + mDirection * MOVE_SPEED);
	mSphereMesh->SetRotation(glm::angleAxis(glm::radians(mCameraRotation), glm::vec3({0.f, 0.f, 1.f})));
	RenderCommands::Init();
	RenderCommands::SetClearColor(clearColor);
	RenderCommands::ClearScreen();
	Renderer::BeginScene(mCamera);
	/* mTexture->Bind(); */
	//Renderer::Submit(mVA, mSpriteShader);
	Renderer::SubmitMesh(mSphereMesh, mMeshShader);
	Renderer::EndScene();
	mDirection = glm::vec3(0);
}

void SandboxLayer::OnImguiRender()
{
	ImGui::Begin("TEST");
	ImGui::End();
}

void SandboxLayer::OnEvent(Event& event)
{
	EventDispatcher dispatcher(event);
	dispatcher.Dispatch<KeyPressedEvent>(BIND_EVENT_FN(SandboxLayer::OnKeyPressed));
	dispatcher.Dispatch<MouseMovedEvent>(BIND_EVENT_FN(SandboxLayer::OnMouseMoved));
}

bool SandboxLayer::OnKeyPressed(KeyPressedEvent& e)
{
	switch(e.GetKeyCode())
	{
	case GLFW_KEY_A:
		mDirection = glm::vec3({ -1, 0, 0 });
		break;
	case GLFW_KEY_D:
		mDirection = glm::vec3({ 1, 0, 0 });
		break;
	case GLFW_KEY_W:
		mDirection = glm::vec3({ 0, 0, -1 });
		break;
	case GLFW_KEY_S:
		mDirection = glm::vec3({ 0, 0, 1 });
		break;
	}
	return true;
}

static float prevVal = 0.f;

bool SandboxLayer::OnMouseMoved(MouseMovedEvent& e)
{
	mCameraRotation -= e.GetX() - prevVal;
	prevVal = e.GetX();
	return true;
}

SandboxApplication::SandboxApplication()
{
	PushLayer(new SandboxLayer());
}

SandboxApplication::~SandboxApplication()
{
}

Application *CreateApplication()
{
	return new SandboxApplication();
}
